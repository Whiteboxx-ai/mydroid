import Foundation
import Observation
import MydroidCore

/// What the controller needs from the app. Closures so tests can stand in for the Hub, the phone and the UI.
struct CallAudioHooks {
    var linkConnected: () -> Bool = { false }
    var phoneName: () -> String = { "phone" }
    /// The phone's IPv4 address on the Mydroid connection, when known.
    var phoneHost: () -> String? = { nil }
    var openDevOptions: () -> Void = {}
    var sendVerify: (String) -> Void = { _ in }
    /// `settings.callAudio` on the phone.
    var setPhoneSetting: (Bool) -> Void = { _ in }
    var answeredOnMac: (String) -> Bool = { _ in false }
    var flash: (String) -> Void = { _ in }
    var log: (String) -> Void = { _ in }
}

/// The audio device side, behind a protocol so the controller can be tested without a sound card.
@MainActor
protocol AudioEngineControlling: AnyObject {
    func requestMicrophone() async -> Bool
    /// Returns whether the microphone is really in use (it can be left out when the Mac has none to use).
    @discardableResult
    func start(link: AudioLink, microphone: Bool, outputUID: String?, inputUID: String?) throws -> Bool
    func stop()
    var muted: Bool { get set }
    /// Called when the audio hardware changed under a running engine (headphones, a device removed).
    var onConfigurationChange: (() -> Void)? { get set }
}

struct CallAudioTiming {
    var setupPoll: Duration = .seconds(1)
    var verifyStep: Duration = .milliseconds(500)
    var verifyTries = 16
    var connectTries = 20
    var tierWait: TimeInterval = 30
    var routeTimeout: Duration = .seconds(8)
    var reconnect = Backoff(base: 3, cap: 45)
    var helperRestart = Backoff(base: 1, cap: 30)
    var meterInterval: Duration = .milliseconds(70)
    var hintAfter: TimeInterval = 90
    static let live = CallAudioTiming()
    static let fast = CallAudioTiming(setupPoll: .milliseconds(20), verifyStep: .milliseconds(10), verifyTries: 5, connectTries: 5,
                                      tierWait: 0.6, routeTimeout: .milliseconds(300),
                                      reconnect: Backoff(base: 0.02, cap: 0.05), helperRestart: Backoff(base: 0.02, cap: 0.05),
                                      meterInterval: .milliseconds(20), hintAfter: 0.2)
}

/// Mac call audio, end to end (PROTOCOL.md section 8): the guided setup, the wireless-debugging connection and its
/// reconnects, the helper on the phone, the Phone / Mac route, and the Mac's audio engine.
@MainActor @Observable
final class CallAudioController {
    // Persisted
    private(set) var prefs: CallAudioPrefs
    // Live
    var adbState: AdbLinkState = .off
    /// The helper process is up (settable for off-screen renders).
    var helperRunning = false
    private(set) var inCall = false
    var route: RouteState = .phone
    var routeError: String?
    var micDenied = false
    /// The Mac has no microphone it can use (or voice processing couldn't start), so the call is listen-only.
    var micUnavailable = false
    /// The Mac's microphone is feeding the call right now.
    var micActive = false
    var setup: SetupProgress?
    let meters = AudioMeters()
    /// Counts and levels from the helper, for the Settings diagnostics line. Never audio.
    private(set) var helperLost = 0

    @ObservationIgnored let adb: AdbControlling
    @ObservationIgnored let engine: AudioEngineControlling
    @ObservationIgnored var hooks: CallAudioHooks
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var timing: CallAudioTiming
    @ObservationIgnored private var connection: VerifiedAdbConnection?
    @ObservationIgnored private var currentHelper: HelperProcess?
    @ObservationIgnored private var currentLink: AudioLink?
    @ObservationIgnored private var supervisor: Task<Void, Never>?
    @ObservationIgnored private var setupTask: Task<Void, Never>?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var routeTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var wake = false
    @ObservationIgnored private var tierSeenAt: Date?
    @ObservationIgnored private var autoRoutePending = false
    /// Set when the user starts a call from the Mac: that call should use the Mac's mic and speakers.
    @ObservationIgnored private var dialedFromMacAt: Date?
    @ObservationIgnored private var micWasActiveThisCall = false
    @ObservationIgnored private var muted = false
    /// Bumped when the phone sends a tier, so the setup can wait for the first one.
    @ObservationIgnored private var tierEvents = 0
    /// Called whenever something the call panel's layout depends on changes.
    @ObservationIgnored var onLayoutChange: (() -> Void)?

    init(adb: AdbControlling, engine: AudioEngineControlling, defaults: UserDefaults, hooks: CallAudioHooks = CallAudioHooks(),
         timing: CallAudioTiming = .live) {
        self.adb = adb; self.engine = engine; self.defaults = defaults; self.hooks = hooks; self.timing = timing
        prefs = CallAudioPrefs.load(defaults)
        engine.onConfigurationChange = { [weak self] in self?.audioHardwareChanged() }
    }

    // MARK: Derived

    var enabled: Bool { prefs.enabled }
    var tier: CallAudioTier? { prefs.enabled ? prefs.tier : nil }
    /// The Phone / Mac switch belongs in the call UI.
    var showsRouteSwitch: Bool { prefs.enabled && (prefs.tier?.canRoute ?? false) }
    /// ...and it can be used right now.
    var routeSwitchUsable: Bool { showsRouteSwitch && helperRunning && !route.isSwitching }
    var routedToMac: Bool { route == .mac }
    /// The "Talk from Mac (experimental)" note applies: full tier, mic on, not yet confirmed.
    var talkIsExperimental: Bool { prefs.tier == .full && prefs.talkEnabled && prefs.talkConfirmed != true }
    var macLabel: String { prefs.tier == .listen ? "Listen on Mac" : "Mac" }
    var available: Bool { adb.isAvailable }

    /// The pending "Hear calls on your Mac" card on the popover.
    var showsPendingCard: Bool { !prefs.enabled && !prefs.cardDismissed && adb.isAvailable }

    func update(_ change: (inout CallAudioPrefs) -> Void) {
        var p = prefs
        change(&p)
        guard p != prefs else { return }
        prefs = p
        p.save(defaults)
        onLayoutChange?()
    }

    func dismissCard() { update { $0.cardDismissed = true } }

    // MARK: Lifecycle

    /// Call at launch: if call audio is on, start keeping the connection up.
    func start() {
        guard prefs.enabled else { return }
        adbState = .searching
        startSupervisor()
    }

    /// The Mydroid link came up or went away, or the network changed: look for the phone sooner.
    func linkChanged(connected: Bool) {
        if connected { wake = true }
    }

    func shutdown() {
        setupTask?.cancel(); meterTask?.cancel()
        stopSupervisor()
        engine.stop()
        currentLink?.stop()
        adb.killServer()
    }

    // MARK: Setup (8.2)

    func beginSetup() {
        cancelSetup()
        guard adb.isAvailable else {
            let p = SetupProgress(phoneName: hooks.phoneName())
            p.stage = .failed(item: 0, message: "Call audio isn\u{2019}t available in this build.")
            setup = p
            return
        }
        let p = SetupProgress(phoneName: hooks.phoneName())
        setup = p
        setupTask = Task { [weak self] in await self?.driveSetup(p) }
    }

    /// The sheet's Try again: a fresh code and a fresh run.
    func retrySetup() { beginSetup() }

    /// Closing the sheet (or Cancel) stops waiting; what's already done stays done.
    func cancelSetup() {
        setupTask?.cancel(); setupTask = nil
        if let p = setup, p.tier == nil, !prefs.enabled { Task { await adb.disconnect(endpoint: nil) } }
        setup = nil
    }

    /// Done on the result screen.
    func finishSetup() {
        setupTask = nil
        setup = nil
    }

    private func fail(_ p: SetupProgress, _ message: String) {
        p.stage = .failed(item: min(p.activeIndex, 3), message: message)
        hooks.log("call audio setup stopped at step \(p.activeIndex)")
    }

    private func driveSetup(_ p: SetupProgress) async {
        guard hooks.linkConnected() else {
            return fail(p, "Connect your \(p.phoneName) first.")
        }
        guard await adb.ensureServer() else {
            return fail(p, "Couldn\u{2019}t start adb. Reopen Mydroid and try again.")
        }
        // Take the supervisor out of the way: it would connect to the phone on its own and race this flow.
        stopSupervisor()
        hooks.openDevOptions()
        let began = Date()
        var pairHost: String?

        // 1 and 2: Developer options, Wireless debugging, QR code scanned.
        while !Task.isCancelled {
            let services = await adb.mdnsServices()
            if p.stage == .devOptions,
               let phoneHost = hooks.phoneHost(),
               services.contains(where: { $0.isConnect && $0.host == phoneHost }) {
                p.stage = .wirelessDebugging
            }
            if let pair = services.first(where: { $0.isPairing && $0.name == p.service }) {
                p.stage = .pairing
                p.detail = "Pairing\u{2026}"
                let r = await adb.pair(endpoint: pair.endpoint, password: p.password)
                guard AdbParsing.pairSucceeded(r.text) else {
                    return fail(p, "Pairing didn't work. Scan the code on this screen.")
                }
                pairHost = pair.host
                break
            }
            if p.hint == nil, Date().timeIntervalSince(began) > timing.hintAfter {
                p.hint = "After scanning, keep Wireless debugging on and both devices on the same Wi\u{2011}Fi."
            }
            try? await Task.sleep(for: timing.setupPoll)
        }
        guard !Task.isCancelled, let host = pairHost else { return }

        // 3: connect, check it's the right phone, grant the keep-alive.
        p.detail = "Connecting\u{2026}"
        var connected: VerifiedAdbConnection?
        var lastFailure: ConnectFailure = .connect
        for _ in 0..<timing.connectTries where !Task.isCancelled {
            if let svc = await adb.mdnsServices().first(where: { $0.isConnect && $0.host == host }) {
                p.detail = "Checking it\u{2019}s your \(p.phoneName)\u{2026}"
                switch await connectVerified(host: svc.host, port: svc.port) {
                case let .success(s): connected = s
                case let .failure(f): lastFailure = f
                }
                // Not being able to prove who it is won't change by asking again.
                if connected != nil || lastFailure == .noAnswer || lastFailure == .linkDown { break }
            }
            try? await Task.sleep(for: timing.setupPoll)
        }
        guard !Task.isCancelled else { return }
        guard let connected else {
            switch lastFailure {
            case .noAnswer:
                return fail(p, "That isn\u{2019}t your \(p.phoneName). Pair the right phone.")
            case .linkDown:
                return fail(p, "Lost the connection. Reconnect and try again.")
            case .connect:
                return fail(p, "Paired, but couldn\u{2019}t connect. Keep Wireless debugging on.")
            }
        }
        p.detail = "Allowing Mydroid to keep this on\u{2026}"
        let grant = await adb.shell(serial: connected.serial, connected.package.grantCommand, timeout: 15)
        hooks.log("keep-alive grant \(grant.ok ? "accepted" : "refused")")

        // Turn it on and let the helper tell us what the phone can do.
        connection = connected
        update { $0.enabled = true; $0.keepAliveGranted = grant.ok; $0.lastHost = host; $0.lastConnected = Date(); $0.tier = nil }
        hooks.setPhoneSetting(true)
        adbState = .connected
        p.stage = .checking
        let before = tierEvents
        startSupervisor()
        let deadline = Date().addingTimeInterval(timing.tierWait)
        while !Task.isCancelled, tierEvents == before, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        guard !Task.isCancelled else { return }
        guard tierEvents != before, let tier = prefs.tier else {
            return fail(p, "Your \(p.phoneName) didn\u{2019}t answer. Update Mydroid on it.")
        }
        p.stage = .result(tier)
        if tier == .none {
            // Nothing to gain by leaving wireless debugging on, so put everything back.
            await undo(announce: false)
            update { $0.tier = CallAudioTier.none }
        }
    }

    // MARK: Turn off (8.2.6)

    /// Disconnect, revoke the grant, tell the phone to stop keeping wireless debugging on.
    func turnOff() { Task { await undo(announce: true) } }

    private func undo(announce: Bool) async {
        stopSupervisor()
        engine.stop()
        stopMeters()
        route = .phone
        if let connection, await adb.isOnline(serial: connection.serial) {
            _ = await adb.shell(serial: connection.serial, connection.package.revokeCommand, timeout: 10)
        }
        await adb.disconnect(endpoint: nil)
        connection = nil
        hooks.setPhoneSetting(false)
        adbState = .off
        helperRunning = false
        update { $0.enabled = false; $0.keepAliveGranted = false; $0.talkCheckPending = false }
        if announce { hooks.flash("Call audio is off. You can turn off Developer options.") }
    }

    // MARK: Connecting (8.2.3, 8.2.4)

    enum ConnectFailure: Error, Equatable { case connect, noAnswer, linkDown }

    private struct VerifiedAdbConnection {
        let serial: String
        let package: CallAudioAndroidPackage
    }

    /// `adb connect`, then prove it is the phone paired with Mydroid: the phone writes a fresh nonce, and we read it back.
    private func connectVerified(host: String, port: Int) async -> Result<VerifiedAdbConnection, ConnectFailure> {
        let endpoint = "\(host):\(port)"
        let r = await adb.connect(endpoint: endpoint)
        guard AdbParsing.connectSucceeded(r.text) else { return .failure(.connect) }
        guard hooks.linkConnected() else { await adb.disconnect(endpoint: endpoint); return .failure(.linkDown) }
        let nonce = MydroidCrypto.randomBytes(16).hex
        hooks.sendVerify(nonce)
        for _ in 0..<timing.verifyTries {
            try? await Task.sleep(for: timing.verifyStep)
            if Task.isCancelled { break }
            for package in CallAudioAndroidPackage.allCases where !Task.isCancelled {
                let f = await adb.shell(serial: endpoint, "cat \(package.verifyPath)", timeout: 8)
                if !Task.isCancelled, f.ok, f.out.trimmingCharacters(in: .whitespacesAndNewlines) == nonce {
                    return .success(VerifiedAdbConnection(serial: endpoint, package: package))
                }
            }
        }
        // Never said yes: don't leave a shell open to a device we couldn't identify.
        await adb.disconnect(endpoint: endpoint)
        return .failure(.noAnswer)
    }

    // MARK: Supervisor: keep adb connected and the helper running

    /// Stops keeping adb up, and the helper with it (a cancelled task alone would leave the helper running).
    private func stopSupervisor() {
        supervisor?.cancel(); supervisor = nil
        currentHelper?.stop()
    }

    private func startSupervisor() {
        stopSupervisor()
        guard prefs.enabled else { return }
        supervisor = Task { [weak self] in await self?.superviseLoop() }
    }

    private func sleepOrWake(_ seconds: TimeInterval) async {
        var left = seconds
        // A nudge that arrived while we were busy (the phone link just came up) must not be lost: only consume it here.
        while left > 0, !wake, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            left -= 0.25
        }
        wake = false
    }

    private func superviseLoop() async {
        var reconnect = timing.reconnect
        var helperBackoff = timing.helperRestart
        while !Task.isCancelled, prefs.enabled {
            if let connection {
                adbState = .connected
                let started = Date()
                await runHelper(connection: connection)
                if Task.isCancelled { break }
                if Date().timeIntervalSince(started) > 60 { helperBackoff.reset() }
                if await adb.isOnline(serial: connection.serial) {
                    await sleepOrWake(helperBackoff.next())
                    continue
                }
                self.connection = nil
                adbState = .searching
            }
            if hooks.linkConnected(), adb.isAvailable {
                if let verified = await reconnectToPhone() {
                    connection = verified; adbState = .connected
                    reconnect.reset(); helperBackoff.reset()
                    update { $0.lastConnected = Date() }
                    continue
                }
                adbState = .unreachable
            } else {
                adbState = .searching
            }
            await sleepOrWake(reconnect.next())
        }
    }

    /// Finds the phone's `_adb-tls-connect` service (its port changes every time wireless debugging toggles) and connects.
    private func reconnectToPhone() async -> VerifiedAdbConnection? {
        guard await adb.ensureServer() else { return nil }
        let known = hooks.phoneHost() ?? prefs.lastHost
        let services = await adb.mdnsServices().filter(\.isConnect)
        // With a known address only that phone is tried; otherwise the nonce check decides.
        let candidates = known.map { h in services.filter { $0.host == h } } ?? services
        for svc in candidates where !Task.isCancelled {
            if case let .success(s) = await connectVerified(host: svc.host, port: svc.port) {
                update { $0.lastHost = svc.host }
                return s
            }
        }
        return nil
    }

    // MARK: Helper session (8.3)

    private func runHelper(connection: VerifiedAdbConnection) async {
        let serial = connection.serial
        let host = serial.split(separator: ":").first.map(String.init) ?? serial
        guard let macHost = LocalAddress.reaching(host: host) else { hooks.log("no route to the phone for audio"); return }
        let key = MydroidCrypto.randomBytes(32)
        guard let link = try? AudioLink(key: key) else { hooks.log("couldn't open the audio socket"); return }
        link.start()
        let helper = adb.makeHelper(serial: serial, package: connection.package)
        helper.onLine = { [weak self] line in
            guard let ev = HelperProtocol.parse(line: line) else { return }
            Task { @MainActor in self?.handle(ev) }
        }
        currentLink = link
        currentHelper = helper
        let once = Once()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            helper.onExit = { _ in if once.fire() { cont.resume() } }
            guard helper.start() else { if once.fire() { cont.resume() }; return }
            helper.send(HelperProtocol.hello(macHost: macHost, udpPort: link.port, key: key))
            helperRunning = true
            hooks.log("helper started")
        }
        // The helper is gone (it quit, adb dropped or the phone went away). A newer session may already own the state.
        hooks.log("helper stopped")
        link.stop()
        if currentHelper === helper {
            helperRunning = false
            currentHelper = nil
            currentLink = nil
            endRouting()
            inCall = false
        }
    }

    private func handle(_ ev: HelperEvent) {
        switch ev {
        case let .tier(t):
            update { $0.tier = t }
            tierEvents += 1
            onLayoutChange?()
        case let .call(inCall):
            self.inCall = inCall
            if inCall, autoRoutePending { autoRoutePending = false; requestRoute(.mac) }
            if !inCall { endRouting(); autoRoutePending = false }
        case let .routed(to, error):
            routeTimeoutTask?.cancel()
            if let error {
                hooks.log("route refused: \(error)")
                routeError = "Couldn\u{2019}t switch to your Mac. \(error)"
                route = .phone
                endRouting()
            } else if to == .mac {
                route = .mac
                routeError = nil
                startEngine()
            } else {
                endRouting()
            }
            onLayoutChange?()
        case let .stats(_, _, lost):
            helperLost = lost
        }
    }

    // MARK: Routing

    /// The Phone / Mac switch.
    func requestRoute(_ r: AudioRoute) {
        guard routeSwitchUsable || (r == .phone && route == .mac), let helper = currentHelper else { return }
        if r == .mac, !(prefs.tier?.canRoute ?? false) { return }
        routeError = nil
        route = .switching(to: r)
        helper.send(HelperProtocol.route(to: r))
        onLayoutChange?()
        routeTimeoutTask?.cancel()
        routeTimeoutTask = Task { [weak self, timing] in
            try? await Task.sleep(for: timing.routeTimeout)
            guard !Task.isCancelled, let self, self.route.isSwitching else { return }
            self.route = .phone
            self.routeError = "No answer. The call stays on your phone."
            self.endRouting()
            self.onLayoutChange?()
        }
    }

    /// Ends Mac audio locally: engine off, meter off, route back to the phone, and the "did they hear you" question if it's due.
    private func endRouting() {
        let wasMac = route == .mac || engineRunning
        routeTimeoutTask?.cancel()
        route = .phone
        if engineRunning { engine.stop(); engineRunning = false }
        stopMeters()
        if wasMac, micWasActiveThisCall, prefs.talkConfirmed == nil, !prefs.talkCheckPending {
            update { $0.talkCheckPending = true }
        }
        micActive = false
        micUnavailable = false
        micWasActiveThisCall = false
        onLayoutChange?()
    }

    @ObservationIgnored private var engineRunning = false

    private func startEngine() {
        guard let link = currentLink else { return }
        let wantMic = prefs.tier == .full && prefs.talkEnabled
        let out = prefs.outputUID, inp = prefs.inputUID
        Task { [weak self] in
            guard let self else { return }
            var mic = false
            if wantMic {
                mic = await engine.requestMicrophone()
                micDenied = !mic
            }
            // The route may have moved on while the permission sheet was up.
            guard route == .mac, currentLink === link else { return }
            do {
                engine.muted = muted
                let micOn = try engine.start(link: link, microphone: mic, outputUID: out, inputUID: inp)
                engineRunning = true
                micActive = micOn
                micUnavailable = mic && !micOn
                if micOn { micWasActiveThisCall = true }
                startMeters(link: link)
                onLayoutChange?()
            } catch {
                hooks.log("audio engine failed to start: \(error.localizedDescription)")
                routeError = "Mac audio couldn\u{2019}t start. The call stays on your phone."
                route = .phone
                currentHelper?.send(HelperProtocol.route(to: .phone))
                onLayoutChange?()
            }
        }
    }

    private func audioHardwareChanged() {
        guard engineRunning, let link = currentLink else { return }
        let mic = micActive
        engine.stop()
        do { micActive = try engine.start(link: link, microphone: mic, outputUID: prefs.outputUID, inputUID: prefs.inputUID) } catch {
            routeError = "Mac audio stopped when the audio device changed."
            requestRoute(.phone)
        }
    }

    /// The device pickers in Settings. A running call switches over at once.
    func setDevices(output: String??, input: String??) {
        update {
            if let output { $0.outputUID = output }
            if let input { $0.inputUID = input }
        }
        audioHardwareChanged()
    }

    func setMuted(_ m: Bool) {
        muted = m
        engine.muted = m
    }

    // MARK: Meters

    private func startMeters(link: AudioLink) {
        meterTask?.cancel()
        meterTask = Task { [weak self, timing] in
            while !Task.isCancelled {
                try? await Task.sleep(for: timing.meterInterval)
                guard let self else { return }
                let s = link.stats
                let rx = PCM.meter(rms: s.rxLevel)
                let tx = (self.micActive && !self.muted) ? PCM.meter(rms: s.txLevel) : 0
                self.meters.rx = max(rx, self.meters.rx * 0.82)
                self.meters.tx = max(tx, self.meters.tx * 0.82)
            }
        }
    }

    private func stopMeters() {
        meterTask?.cancel(); meterTask = nil
        meters.reset()
    }

    // MARK: Calls

    func callChanged(old: CallInfo?, new: CallInfo?) {
        guard let new else { if old != nil { callEnded() }; return }
        if new.phase == .ended { callEnded(); return }
        if new.phase == .active, old?.phase != .active, prefs.routeOnAnswer, routeSwitchUsable, hooks.answeredOnMac(new.callId) {
            if inCall { requestRoute(.mac) } else { autoRoutePending = true }
        }
        // A call the user started on the Mac uses Mac audio straight away (when this phone supports it).
        if !new.incoming, new.phase == .active, old?.phase != .active, routeSwitchUsable,
           let t = dialedFromMacAt, Date().timeIntervalSince(t) < 30 {
            dialedFromMacAt = nil
            if inCall { requestRoute(.mac) } else { autoRoutePending = true }
        }
        if new.muted != old?.muted { setMuted(new.muted) }
    }

    /// Called right before the Mac asks the phone to dial.
    func noteDialFromMac() { dialedFromMacAt = Date() }

    private func callEnded() {
        autoRoutePending = false
        dialedFromMacAt = nil
        if route == .mac || route.isSwitching { endRouting() }
    }

    // MARK: "Did the other person hear you?"

    func answerTalkCheck(heard: Bool) {
        update {
            $0.talkConfirmed = heard
            $0.talkCheckPending = false
            if !heard { $0.talkEnabled = false }
        }
    }

    func setTalkEnabled(_ on: Bool) {
        update {
            $0.talkEnabled = on
            if on, $0.talkConfirmed == false { $0.talkConfirmed = nil }
        }
    }

    func setRouteOnAnswer(_ on: Bool) { update { $0.routeOnAnswer = on } }
}

/// Fires once, from any thread. For resuming a continuation exactly one time.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

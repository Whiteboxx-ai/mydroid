import XCTest
@testable import MydroidCore
@testable import Mydroid

// The setup flow, reconnects, helper supervision and routing, with a fake adb, helper and audio engine.

final class FakeHelper: HelperProcess, @unchecked Sendable {
    var onLine: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    unowned let adb: FakeAdb
    var sent: [String] = []
    private(set) var running = false
    init(adb: FakeAdb) { self.adb = adb }

    func start() -> Bool { running = true; return true }
    func send(_ line: String) {
        sent.append(line)
        if line.contains("\"cmd\":\"hello\"") {
            adb.hellos += 1
            if let t = adb.autoTier { emit("{\"ev\":\"tier\",\"tier\":\"\(t.rawValue)\"}", after: 0.01) }
        }
        if line.contains("\"cmd\":\"route\""), adb.answerRoutes {
            let to = line.contains("\"to\":\"mac\"") ? "mac" : "phone"
            if let err = adb.routeError { emit("{\"ev\":\"routed\",\"to\":\"phone\",\"error\":\"\(err)\"}", after: 0.01) }
            else { emit("{\"ev\":\"routed\",\"to\":\"\(to)\"}", after: 0.01) }
        }
    }
    func stop() { crash(0, after: 0.01) }
    func emit(_ line: String, after: TimeInterval = 0) {
        DispatchQueue.global().asyncAfter(deadline: .now() + after) { [weak self] in if self?.running == true { self?.onLine?(line) } }
    }
    func crash(_ code: Int32 = 1, after: TimeInterval = 0) {
        DispatchQueue.global().asyncAfter(deadline: .now() + after) { [weak self] in
            guard let self, self.running else { return }
            self.running = false
            self.onExit?(code)
        }
    }
}

final class FakeAdb: AdbControlling, @unchecked Sendable {
    var isAvailable = true
    var services: [AdbMdnsService] = []
    var pairOutput = "Successfully paired to 127.0.0.1:37891 [guid=adb-x]"
    var connectOutput = "connected to 127.0.0.1:41235"
    var verifyReply: () -> String = { "" }
    var pairedPackage: CallAudioAndroidPackage = .current
    var autoTier: CallAudioTier? = .full
    var answerRoutes = true
    var routeError: String?
    var hellos = 0
    var commands: [String] = []
    var helpers: [FakeHelper] = []
    var connected: Set<String> = []
    var devices: [AdbParsing.Device] = []
    var killed = false

    func ensureServer() async -> Bool { commands.append("start-server"); return true }
    func mdnsServices() async -> [AdbMdnsService] { services }
    func onlineDevices() async -> [AdbParsing.Device] { devices }
    func pair(endpoint: String, password: String) async -> AdbResult {
        commands.append("pair \(endpoint)")
        return AdbResult(status: 0, out: pairOutput, err: "")
    }
    func connect(endpoint: String) async -> AdbResult {
        commands.append("connect \(endpoint)")
        if AdbParsing.connectSucceeded(connectOutput) { connected.insert(endpoint) }
        return AdbResult(status: 0, out: connectOutput, err: "")
    }
    func disconnect(endpoint: String?) async {
        commands.append("disconnect \(endpoint ?? "all")")
        if let e = endpoint { connected.remove(e) } else { connected.removeAll() }
    }
    func shell(serial: String, _ command: String, timeout: TimeInterval) async -> AdbResult {
        commands.append("shell \(command)")
        if command.hasPrefix("cat ") {
            let reply = command == "cat \(pairedPackage.verifyPath)" ? verifyReply() : "stale nonce"
            return AdbResult(status: 0, out: reply + "\n", err: "")
        }
        return AdbResult(status: 0, out: "", err: "")
    }
    func isOnline(serial: String) async -> Bool { connected.contains(serial) }
    func makeHelper(serial: String, package: CallAudioAndroidPackage) -> HelperProcess {
        commands.append("helper \(package.rawValue)")
        let helper = FakeHelper(adb: self)
        helpers.append(helper)
        return helper
    }
    func killServer() { killed = true }
}

@MainActor
final class FakeEngine: AudioEngineControlling {
    var muted = false
    var onConfigurationChange: (() -> Void)?
    var micGranted = true
    var failStart = false
    var starts: [(mic: Bool, out: String?, inp: String?)] = []
    var stops = 0
    var running = false
    func requestMicrophone() async -> Bool { micGranted }
    var micWorks = true
    func start(link: AudioLink, microphone: Bool, outputUID: String?, inputUID: String?) throws -> Bool {
        if failStart { throw CallAudioEngineError.noOutput }
        starts.append((microphone, outputUID, inputUID)); running = true
        return microphone && micWorks
    }
    func stop() { stops += 1; running = false }
}

@MainActor
final class CallAudioControllerTests: XCTestCase {
    final class Env {
        var linkUp = true
        var wirelessDebugging: Bool? = nil
        var verifies: [String] = []
        var phoneSetting: [Bool] = []
        var flashes: [String] = []
        var devOptionsOpened = 0
        var answered: Set<String> = []
    }

    private func make(adb: FakeAdb = FakeAdb(), developerAdb: FakeAdb? = nil, env: Env = Env(), defaults: UserDefaults? = nil)
        -> (CallAudioController, FakeAdb, FakeEngine, Env, UserDefaults) {
        let d = defaults ?? UserDefaults(suiteName: "mydroid.test.\(UUID().uuidString)")!
        let engine = FakeEngine()
        let c = CallAudioController(adb: adb, developerAdb: developerAdb, engine: engine, defaults: d, timing: .fast)
        c.hooks = CallAudioHooks(
            linkConnected: { env.linkUp }, phoneName: { "Pixel 9" }, phoneHost: { "127.0.0.1" },
            wirelessDebugging: { env.wirelessDebugging },
            openDevOptions: { env.devOptionsOpened += 1 },
            sendVerify: { n in env.verifies.append(n); adb.verifyReply = { n }; developerAdb?.verifyReply = { n } },
            setPhoneSetting: { env.phoneSetting.append($0) },
            answeredOnMac: { env.answered.contains($0) },
            flash: { env.flashes.append($0) })
        return (c, adb, engine, env, d)
    }

    private func until(_ what: String = "", timeout: TimeInterval = 4, _ cond: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond(), Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(cond(), "timed out waiting for \(what)", file: file, line: line)
    }

    private func connectService(_ adb: FakeAdb) {
        adb.services = [AdbMdnsService(name: "adb-x", type: "_adb-tls-connect._tcp", host: "127.0.0.1", port: 41235)]
    }
    private func scan(_ adb: FakeAdb, _ p: SetupProgress) {
        adb.services = [AdbMdnsService(name: "adb-x", type: "_adb-tls-connect._tcp", host: "127.0.0.1", port: 41235),
                        AdbMdnsService(name: p.service, type: "_adb-tls-pairing._tcp", host: "127.0.0.1", port: 37891)]
    }

    /// Enabled and connected, for the supervisor and routing tests.
    private func enabled(tier: CallAudioTier = .full) async -> (CallAudioController, FakeAdb, FakeEngine, Env) {
        let (c, adb, e, env, _) = make()
        adb.autoTier = tier
        connectService(adb)
        c.update { $0.enabled = true; $0.keepAliveGranted = true; $0.tier = tier; $0.lastHost = "127.0.0.1" }
        c.start()
        await until("helper up") { c.helperRunning }
        return (c, adb, e, env)
    }

    // MARK: Setup

    func testSetupShowsCodeBeforeDiscoveringWirelessDebugging() async {
        let (c, adb, _, env, _) = make()
        c.beginSetup()
        let p = c.setup!
        await until("QR shown") { p.stage == .devOptions }
        XCTAssertEqual(env.devOptionsOpened, 0, "unknown status must not open phone settings")

        XCTAssertEqual(p.stage, .devOptions)
        XCTAssertTrue(p.showsCode)
        XCTAssertNotNil(QRCode.image(for: p.qrPayload))

        // The scan can be the first service Mydroid discovers on this phone.
        adb.services = [AdbMdnsService(name: p.service, type: "_adb-tls-pairing._tcp", host: "127.0.0.1", port: 37891)]
        await until("pair requested") { adb.commands.contains("pair 127.0.0.1:37891") }
        connectService(adb)
        await until("setup finished") { p.tier == .full }
        c.shutdown()
    }

    func testSetupAdvancesByItselfToTheTierResult() async {
        let (c, adb, _, env, _) = make()
        env.wirelessDebugging = false
        adb.connectOutput = "failed to connect"
        c.beginSetup()
        let p = c.setup!
        var seen: [SetupStage] = []
        func note() { if seen.last != p.stage { seen.append(p.stage) } }
        await until("dev options opened") { env.devOptionsOpened == 1 }
        XCTAssertEqual(p.stage, .devOptions)
        XCTAssertEqual(p.items.map(\.status), [.active, .pending, .pending, .pending])
        note()

        connectService(adb)                                                  // Wireless debugging is on
        await until("step 2") { note(); return p.stage == .wirelessDebugging }
        XCTAssertEqual(p.items.map(\.status), [.done, .active, .pending, .pending])
        XCTAssertTrue(p.showsCode)

        adb.connectOutput = "connected to 127.0.0.1:41235"
        scan(adb, p)                                                         // the phone scanned our code
        await until("result") { note(); return p.isFinished }
        XCTAssertEqual(seen, [.devOptions, .wirelessDebugging, .pairing, .checking, .result(.full)])
        XCTAssertEqual(p.items.map(\.status), [.done, .done, .done, .done])

        XCTAssertTrue(adb.commands.contains("pair 127.0.0.1:37891"))
        XCTAssertTrue(adb.commands.contains("connect 127.0.0.1:41235"))
        XCTAssertTrue(adb.commands.contains("shell \(CallAudioAndroidPackage.current.grantCommand)"))
        XCTAssertTrue(adb.commands.contains("helper \(CallAudioAndroidPackage.current.rawValue)"))
        XCTAssertEqual(env.verifies.count, 1)
        XCTAssertEqual(env.verifies[0].count, 32)
        XCTAssertEqual(env.phoneSetting, [true])
        XCTAssertTrue(c.enabled)
        XCTAssertEqual(c.prefs.tier, .full)
        XCTAssertTrue(c.prefs.keepAliveGranted)
        XCTAssertTrue(c.showsRouteSwitch)

        // The helper got a hello with a LAN address, a UDP port and a fresh 32-byte key.
        let hello = adb.helpers.first?.sent.first ?? ""
        let o = try? JSONSerialization.jsonObject(with: Data(hello.utf8)) as? [String: Any]
        XCTAssertEqual(o?["cmd"] as? String, "hello")
        XCTAssertEqual(o?["macHost"] as? String, "127.0.0.1")
        XCTAssertGreaterThan(o?["udpPort"] as? Int ?? 0, 0)
        XCTAssertEqual(Data(base64Encoded: o?["key"] as? String ?? "")?.count, 32)
        c.shutdown()
    }

    func testExistingWirelessDebuggingConnectionSkipsQRAndLeavesDeveloperAdbAlone() async {
        let developerAdb = FakeAdb()
        let serial = "adb-x._adb-tls-connect._tcp"
        developerAdb.devices = [.init(serial: serial, state: "device")]
        developerAdb.connected = [serial]
        let (controller, privateAdb, _, env, _) = make(developerAdb: developerAdb)
        controller.linkChanged(connected: true)
        XCTAssertFalse(controller.showsPendingCard)
        await until("existing connection verified and enabled") { controller.tier == .full }
        XCTAssertNil(controller.setup)
        XCTAssertFalse(controller.showsPendingCard)
        XCTAssertEqual(env.devOptionsOpened, 0)
        XCTAssertEqual(env.verifies.count, 1)
        XCTAssertTrue(privateAdb.commands.isEmpty)
        XCTAssertTrue(developerAdb.commands.contains("helper \(CallAudioAndroidPackage.current.rawValue)"))
        controller.turnOff()
        await until("call audio off") { !controller.enabled }
        controller.linkChanged(connected: true)
        XCTAssertFalse(controller.checkingExistingConnection)
        controller.shutdown()
        XCTAssertEqual(developerAdb.connected, [serial])
        XCTAssertFalse(developerAdb.killed)
        XCTAssertFalse(developerAdb.commands.contains { $0.hasPrefix("shell pm ") || $0.hasPrefix("disconnect") })
    }

    func testLegacyAppWithTheMatchingNonceOwnsCallAudio() async {
        let (c, adb, _, _, _) = make()
        adb.pairedPackage = .legacy
        c.beginSetup()
        let p = c.setup!
        scan(adb, p)
        await until("legacy setup") { p.tier == .full }

        let legacy = CallAudioAndroidPackage.legacy
        let current = CallAudioAndroidPackage.current
        XCTAssertTrue(adb.commands.contains("shell cat \(current.verifyPath)"))
        XCTAssertTrue(adb.commands.contains("shell \(legacy.grantCommand)"))
        XCTAssertTrue(adb.commands.contains("helper \(legacy.rawValue)"))
        XCTAssertFalse(adb.commands.contains("shell \(current.grantCommand)"))
        XCTAssertFalse(adb.commands.contains("helper \(current.rawValue)"))
        c.turnOff()
        await until("legacy turned off") { !c.enabled }
        XCTAssertTrue(adb.commands.contains("shell \(legacy.revokeCommand)"))
        c.shutdown()
    }

    func testAnotherPhoneIsRefusedAndDisconnected() async {
        let (c, adb, _, env, _) = make()
        adb.verifyReply = { "not-our-nonce" }
        c.hooks.sendVerify = { env.verifies.append($0) }                    // the phone never writes the nonce we sent
        c.beginSetup()
        let p = c.setup!
        scan(adb, p)
        await until("failure") { p.failure != nil }
        XCTAssertTrue(p.failure!.contains("Pixel 9"))
        XCTAssertEqual(p.items[2].status, .failed)
        XCTAssertTrue(adb.commands.contains("disconnect 127.0.0.1:41235"), "an unverified device must not stay connected")
        XCTAssertFalse(c.enabled)
        XCTAssertTrue(env.phoneSetting.isEmpty)
        XCTAssertFalse(adb.commands.contains { $0.hasPrefix("shell pm grant ") }, "no grant for a device we couldn't identify")
    }

    func testNoneTierIsExplainedAndEverythingIsUndone() async {
        let (c, adb, _, env, _) = make()
        adb.autoTier = CallAudioTier.none
        c.beginSetup()
        let p = c.setup!
        scan(adb, p)
        await until("result") { p.isFinished }
        XCTAssertEqual(p.tier, CallAudioTier.none)
        await until("undone") { !c.enabled && env.phoneSetting == [true, false] }
        XCTAssertTrue(adb.commands.contains("shell \(CallAudioAndroidPackage.current.revokeCommand)"))
        XCTAssertTrue(adb.commands.contains("disconnect all"))
        XCTAssertEqual(c.prefs.tier, CallAudioTier.none)
        XCTAssertFalse(c.showsRouteSwitch)
        XCTAssertEqual(c.adbState, .off)
        XCTAssertEqual(TierCopy.detail(.none), "You can still answer, decline and mute from your Mac.")
    }

    func testSetupNeedsTheMydroidLinkAndAdb() async {
        let (c, _, _, env, _) = make()
        env.linkUp = false
        c.beginSetup()
        await until("failed") { c.setup?.failure != nil }
        XCTAssertTrue(c.setup!.failure!.hasPrefix("Connect your Pixel 9"))

        let (c2, adb2, _, _, _) = make()
        adb2.isAvailable = false
        c2.beginSetup()
        XCTAssertTrue(c2.setup!.failure!.contains("available in this build"))
        XCTAssertFalse(c2.showsPendingCard)
    }

    func testFailedPairingSaysSo() async {
        let (c, adb, _, _, _) = make()
        adb.pairOutput = "Failed: Wrong password or connection was dropped"
        c.beginSetup()
        scan(adb, c.setup!)
        await until("failure") { c.setup?.failure != nil }
        XCTAssertTrue(c.setup!.failure!.hasPrefix("Pairing didn't work"))
        XCTAssertEqual(c.setup!.items[2].status, .failed)
        XCTAssertFalse(c.enabled)
    }

    // MARK: Staying connected

    func testReconnectsOnItsOwnWhenWirelessDebuggingComesBack() async {
        let (c, adb, _, env, _) = make()
        adb.autoTier = .full
        c.update { $0.enabled = true; $0.tier = .full; $0.lastHost = "127.0.0.1" }
        c.start()                                                            // wireless debugging isn't there yet
        await until("searching") { c.adbState == .unreachable || c.adbState == .searching }
        XCTAssertFalse(c.helperRunning)
        connectService(adb)
        await until("connected and helper up") { c.adbState == .connected && c.helperRunning }
        XCTAssertGreaterThanOrEqual(env.verifies.count, 1, "every reconnect proves it is the same phone")
        c.shutdown()
        XCTAssertTrue(adb.killed)
    }

    func testHelperIsRestartedWithBackoffWhenItDies() async {
        let (c, adb, _, _) = await enabled()
        XCTAssertEqual(adb.helpers.count, 1)
        adb.helpers[0].crash()
        await until("restarted") { adb.helpers.count == 2 && c.helperRunning }
        adb.helpers[1].crash()
        await until("restarted again") { adb.helpers.count == 3 && c.helperRunning }
        XCTAssertEqual(adb.hellos, 3)
        c.shutdown()
    }

    func testLostAdbConnectionStopsTheHelperUntilItIsBack() async {
        let (c, adb, _, _) = await enabled()
        adb.connected.removeAll()
        adb.services = []
        adb.helpers[0].crash()
        await until("noticed") { !c.helperRunning && c.adbState != .connected }
        connectService(adb)
        await until("back") { c.helperRunning && c.adbState == .connected }
        c.shutdown()
    }

    // MARK: Routing

    func testRouteToMacStartsTheEngineAndBackStopsIt() async {
        let (c, adb, engine, _) = await enabled()
        c.requestRoute(.mac)
        XCTAssertEqual(c.route, .switching(to: .mac))
        await until("routed") { c.route == .mac && engine.running }
        XCTAssertEqual(engine.starts.count, 1)
        XCTAssertTrue(engine.starts[0].mic, "full tier talks")
        XCTAssertTrue(adb.helpers[0].sent.contains(HelperProtocol.route(to: .mac)))
        c.requestRoute(.phone)
        await until("back") { c.route == .phone && !engine.running }
        c.shutdown()
    }

    func testListenTierNeverTouchesTheMicrophone() async {
        let (c, _, engine, _) = await enabled(tier: .listen)
        XCTAssertEqual(c.macLabel, "Listen on Mac")
        c.requestRoute(.mac)
        await until("routed") { engine.running }
        XCTAssertFalse(engine.starts[0].mic)
        XCTAssertFalse(c.talkIsExperimental)
        c.shutdown()
    }

    func testDeniedMicrophoneFallsBackToListening() async {
        let (c, _, engine, _) = await enabled()
        engine.micGranted = false
        c.requestRoute(.mac)
        await until("routed") { engine.running }
        XCTAssertFalse(engine.starts[0].mic)
        XCTAssertTrue(c.micDenied)
        c.shutdown()
    }

    func testNoUsableMicrophoneFallsBackToListening() async {
        let (c, _, engine, _) = await enabled()
        engine.micWorks = false
        c.requestRoute(.mac)
        await until("routed") { engine.running }
        XCTAssertFalse(c.micActive)
        XCTAssertTrue(c.micUnavailable)
        XCTAssertFalse(c.micDenied)
        c.requestRoute(.phone)
        await until("back") { !engine.running }
        XCTAssertFalse(c.prefs.talkCheckPending, "no microphone was used, so there is nothing to ask about")
        c.shutdown()
    }

    func testRefusedRouteStaysOnThePhoneWithAPlainMessage() async {
        let (c, adb, engine, _) = await enabled()
        adb.routeError = "Android wouldn't give the helper call audio"
        c.requestRoute(.mac)
        await until("refused") { c.routeError != nil }
        XCTAssertEqual(c.route, .phone)
        XCTAssertFalse(engine.running)
        XCTAssertTrue(c.routeError!.contains("Android wouldn't give the helper call audio"))
        c.shutdown()
    }

    func testNoAnswerFromThePhoneTimesOut() async {
        let (c, adb, _, _) = await enabled()
        adb.answerRoutes = false
        c.requestRoute(.mac)
        await until("timeout") { c.routeError != nil }
        XCTAssertEqual(c.route, .phone)
        c.shutdown()
    }

    func testEngineFailureReturnsTheCallToThePhone() async {
        let (c, adb, engine, _) = await enabled()
        engine.failStart = true
        c.requestRoute(.mac)
        await until("fell back") { c.routeError != nil }
        XCTAssertEqual(c.route, .phone)
        XCTAssertTrue(adb.helpers[0].sent.contains(HelperProtocol.route(to: .phone)))
        c.shutdown()
    }

    func testCallEndingStopsMacAudioAndAsksOnceAboutTalking() async {
        let (c, adb, engine, _) = await enabled()
        c.requestRoute(.mac)
        await until("routed") { engine.running }
        XCTAssertTrue(c.micActive)
        XCTAssertTrue(c.talkIsExperimental)
        adb.helpers[0].emit("{\"ev\":\"call\",\"inCall\":false}")
        await until("stopped") { !engine.running && c.route == .phone }
        XCTAssertTrue(c.prefs.talkCheckPending)

        c.answerTalkCheck(heard: true)
        XCTAssertEqual(c.prefs.talkConfirmed, true)
        XCTAssertFalse(c.prefs.talkCheckPending)
        XCTAssertFalse(c.talkIsExperimental, "the experimental note goes once confirmed")

        // Not asked again after a second routed call.
        c.requestRoute(.mac)
        await until("routed again") { engine.running }
        adb.helpers[0].emit("{\"ev\":\"call\",\"inCall\":false}")
        await until("stopped again") { !engine.running }
        XCTAssertFalse(c.prefs.talkCheckPending)
        c.shutdown()
    }

    func testSayingNoTurnsTalkingOffAndItCanBeRetried() async {
        let (c, _, _, _) = await enabled()
        c.update { $0.talkCheckPending = true }
        c.answerTalkCheck(heard: false)
        XCTAssertFalse(c.prefs.talkEnabled)
        XCTAssertEqual(c.prefs.talkConfirmed, false)
        c.setTalkEnabled(true)
        XCTAssertTrue(c.prefs.talkEnabled)
        XCTAssertNil(c.prefs.talkConfirmed)
        c.shutdown()
    }

    func testAnsweringOnTheMacRoutesToMacWhenTheSettingIsOn() async {
        let (c, adb, engine, env) = await enabled()
        c.setRouteOnAnswer(true)
        env.answered = ["call-1"]
        let ringing = CallInfo(callId: "call-1", phase: .ringing, incoming: true, number: "+1", name: nil, startedAt: Date())
        var active = ringing; active.phase = .active
        c.callChanged(old: nil, new: ringing)
        c.callChanged(old: ringing, new: active)                             // the helper hasn't said it's in a call yet
        XCTAssertEqual(c.route, .phone)
        adb.helpers[0].emit("{\"ev\":\"call\",\"inCall\":true}")
        await until("routed to Mac") { c.route == .mac && engine.running }

        // Left alone when the setting is off, or the call wasn't answered on the Mac.
        c.callChanged(old: active, new: nil)
        await until("ended") { !engine.running }
        c.setRouteOnAnswer(false)
        c.callChanged(old: nil, new: ringing)
        c.callChanged(old: ringing, new: active)
        adb.helpers[0].emit("{\"ev\":\"call\",\"inCall\":true}")
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(c.route, .phone)
        c.shutdown()
    }

    func testMuteReachesTheEngine() async {
        let (c, _, engine, _) = await enabled()
        var call = CallInfo(callId: "c", phase: .active, incoming: true, number: nil, name: nil, startedAt: Date())
        let before = call
        call.muted = true
        c.callChanged(old: before, new: call)
        XCTAssertTrue(engine.muted)
        c.shutdown()
    }

    func testDeviceChoiceIsRememberedAndAppliedToARunningEngine() async {
        let (c, _, engine, _) = await enabled()
        c.requestRoute(.mac)
        await until("routed") { engine.running }
        c.setDevices(output: .some("speakers-uid"), input: .some("mic-uid"))
        XCTAssertEqual(engine.starts.last?.out, "speakers-uid")
        XCTAssertEqual(engine.starts.last?.inp, "mic-uid")
        c.setDevices(output: .some(nil), input: nil)                         // back to the system default
        XCTAssertNil(c.prefs.outputUID)
        XCTAssertEqual(c.prefs.inputUID, "mic-uid")
        c.shutdown()
    }

    // MARK: Turning it off, and what is remembered

    func testTurnOffUndoesEverything() async {
        let (c, adb, engine, env) = await enabled()
        c.turnOff()
        await until("off") { !c.enabled && !c.helperRunning }
        XCTAssertEqual(c.adbState, .off)
        XCTAssertTrue(adb.commands.contains("shell \(CallAudioAndroidPackage.current.revokeCommand)"))
        XCTAssertTrue(adb.commands.contains("disconnect all"))
        XCTAssertEqual(env.phoneSetting.last, false)
        XCTAssertFalse(engine.running)
        XCTAssertTrue(env.flashes.last?.contains("Developer options") == true)
        XCTAssertFalse(c.showsRouteSwitch)
    }

    func testPendingCardAndNotNowArePermanent() {
        let (c, _, _, _, d) = make()
        XCTAssertTrue(c.showsPendingCard)
        c.dismissCard()
        XCTAssertFalse(c.showsPendingCard)
        let again = CallAudioController(adb: FakeAdb(), engine: FakeEngine(), defaults: d)
        XCTAssertFalse(again.showsPendingCard, "Not now survives a relaunch")
        XCTAssertEqual(again.prefs.cardDismissed, true)
    }

    func testPrefsSurviveRelaunchAndOlderBlobsDecode() throws {
        let (c, _, _, _, d) = make()
        c.update { $0.enabled = true; $0.tier = .listen; $0.routeOnAnswer = true; $0.outputUID = "x"; $0.lastConnected = Date(timeIntervalSince1970: 5) }
        let again = CallAudioController(adb: FakeAdb(), engine: FakeEngine(), defaults: d)
        XCTAssertEqual(again.prefs, c.prefs)
        let old = try JSONDecoder().decode(CallAudioPrefs.self, from: Data("{\"enabled\":true}".utf8))
        XCTAssertTrue(old.enabled); XCTAssertTrue(old.talkEnabled); XCTAssertNil(old.talkConfirmed)
    }

    func testRouteSwitchOnlyWhenTheTierAllowsIt() {
        let (c, _, _, _, _) = make()
        XCTAssertFalse(c.showsRouteSwitch)
        c.update { $0.enabled = true; $0.tier = CallAudioTier.none }
        XCTAssertFalse(c.showsRouteSwitch)
        c.update { $0.tier = .listen }
        XCTAssertTrue(c.showsRouteSwitch)
        c.update { $0.enabled = false }
        XCTAssertFalse(c.showsRouteSwitch)
    }
}

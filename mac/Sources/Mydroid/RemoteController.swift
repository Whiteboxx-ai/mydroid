import SwiftUI
import AppKit
import ApplicationServices
import MydroidCore

// PROTOCOL.md section 10 on the Mac: input injection, the Accessibility card, the laser and presenting detection.

enum LaserColor: String, Codable, CaseIterable, Identifiable {
    case red, orange, green, blue
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .red: return Color(red: 1, green: 0.13, blue: 0.1)
        case .orange: return Color(red: 1, green: 0.55, blue: 0.05)
        case .green: return Color(red: 0.1, green: 0.85, blue: 0.3)
        case .blue: return Color(red: 0.2, green: 0.5, blue: 1)
        }
    }
    var nsColor: NSColor { NSColor(color) }
}

/// The part of Remote that runs on the network queue. It holds no UI: a lock-protected trust cache, the input pipeline and the laser mailbox.
/// Moves go from here straight to the injector's own queue, with no hop through the main actor.
final class RemoteInputRouter: @unchecked Sendable {
    let laser = LaserMailbox()
    private let pipeline: InputPipeline
    private let injector: InputInjector
    private let checker: AccessibilityChecking
    private let lock = NSLock()
    private var cachedTrust = false
    private var cachedAt: TimeInterval = -1000
    private var laserOn = false
    private var lastAsk: TimeInterval = -1000

    /// Input arrived while Accessibility is off (at most every 2 s). Runs on the network queue.
    var onNeedsPermission: () -> Void = {}
    /// The trust answer changed since last time (granted or revoked while running).
    var onTrustChanged: () -> Void = {}
    var onLaser: (Bool) -> Void = { _ in }

    init(poster: SyntheticEventPoster, checker: AccessibilityChecking) {
        self.checker = checker
        injector = InputInjector(poster: poster)
        let injector = self.injector
        pipeline = InputPipeline { injector.handle($0) }
    }

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// `AXIsProcessTrusted` is cheap but not free, so a pointer stream reuses the answer for a second.
    private func trusted() -> Bool {
        lock.lock()
        let t = Self.now()
        if t - cachedAt < 1 { defer { lock.unlock() }; return cachedTrust }
        lock.unlock()
        return refresh()
    }

    @discardableResult
    func refresh() -> Bool {
        let v = checker.isTrusted
        lock.lock()
        let changed = v != cachedTrust && cachedAt > 0
        cachedTrust = v
        cachedAt = Self.now()
        lock.unlock()
        if changed { onTrustChanged() }
        return v
    }

    /// Network queue.
    func receive(_ input: RemoteInput) {
        if case let .laser(on, x, y) = input {
            laser.set(x: x, y: y)
            lock.lock(); let change = on != laserOn; laserOn = on; lock.unlock()
            if change { onLaser(on) }
            return
        }
        if trusted() {
            pipeline.submit(input)
        } else {
            lock.lock()
            let t = Self.now()
            let ask = t - lastAsk > 2
            if ask { lastAsk = t }
            lock.unlock()
            if ask { onNeedsPermission() }
        }
    }

    func setReverseScroll(_ on: Bool) {
        let injector = self.injector
        pipeline.perform { injector.reverseScroll = on }
    }

    /// The session ended: let go of a drag in progress and hide the laser.
    func sessionEnded() {
        let injector = self.injector
        pipeline.perform { injector.releaseAll() }
        lock.lock(); let was = laserOn; laserOn = false; lock.unlock()
        if was { onLaser(false) }
    }
}

@MainActor @Observable
final class RemoteController {
    /// Whether macOS lets Mydroid post input right now.
    private(set) var trusted: Bool
    /// The Accessibility card is wanted (the phone asked, or input arrived without permission).
    private(set) var cardRequested = false
    /// The app that is presenting, if any.
    private(set) var presenting: String?
    /// Keynote can be asked directly whether a slideshow is playing (Automation permission).
    private(set) var keynoteAutomation: PresentingMonitor.AutomationState = .notInstalled

    @ObservationIgnored let checker: SystemAccessibility
    @ObservationIgnored let poster = CGEventPoster()
    @ObservationIgnored let router: RemoteInputRouter
    @ObservationIgnored private weak var hub: Hub?
    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private var dismissedAt: Date?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let panel = AccessibilityPromptController()
    @ObservationIgnored let laserOverlay = LaserOverlay()
    @ObservationIgnored let presentingMonitor = PresentingMonitor()
    @ObservationIgnored private var live = false

    var needsAccessCard: Bool { cardRequested && !trusted }

    /// `live` false builds the same object without timers, observers or windows (fixtures and tests).
    init(hub: Hub, live: Bool = true) {
        self.hub = hub
        self.live = live
        let checker = SystemAccessibility()
        self.checker = checker
        trusted = live ? checker.isTrusted : false
        router = RemoteInputRouter(poster: poster, checker: checker)
        guard live else { return }
        router.refresh()
        router.onNeedsPermission = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.permissionNeeded(explicit: false) } }
        }
        router.onTrustChanged = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.recheck() } }
        }
        router.onLaser = { [weak self] on in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.laserOverlay.setOn(on) } }
        }
        laserOverlay.mailbox = router.laser
        panel.controller = self
        presentingMonitor.onChange = { [weak self] app in self?.setPresenting(app) }
    }

    /// Hook the Hub up and start watching. Call once, after the Hub exists.
    func start(hub: Hub) {
        guard live else { return }
        hub.onRemoteInput = { [router] in router.receive($0) }
        hub.setRemoteState(accessibility: trusted, presenting: presenting)
        // Granting happens in System Settings, so coming back to the app is a good moment to look again.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheck() }
        })
        presentingMonitor.start()
        keynoteAutomation = presentingMonitor.automationState
    }

    /// The same, for the phone's reverse-scroll and the laser colour (Settings > Remote).
    func apply(prefs: MacPrefs) {
        router.setReverseScroll(prefs.reverseScroll)
        laserOverlay.color = prefs.laserColor.nsColor
    }

    // MARK: Accessibility

    /// `remote.ask`, or input arriving without permission. An explicit ask always shows the card; input only does if the user hasn't
    /// just said "Not now".
    func permissionNeeded(explicit: Bool) {
        recheck()
        guard !trusted else { return }
        if !explicit, let d = dismissedAt, Date().timeIntervalSince(d) < 120 { return }
        showCard()
    }

    func showCard() {
        dismissedAt = nil
        cardRequested = true
        guard live else { return }
        panel.show()
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheck() }
        }
    }

    /// "Not now".
    func dismissCard() {
        dismissedAt = Date()
        hideCard()
    }

    private func hideCard() {
        cardRequested = false
        poll?.invalidate(); poll = nil
        if live { panel.hide() }
    }

    func openAccessibilitySettings() {
        checker.requestAndOpenSettings()
        // The pane takes a moment; check again soon so the card closes by itself once the switch is on.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in MainActor.assumeIsolated { self?.recheck() } }
    }

    func recheck() {
        guard live else { return }
        let t = router.refresh()
        if t != trusted {
            trusted = t
            hub?.setRemoteState(accessibility: t, presenting: presenting)
        }
        if t, cardRequested { hideCard() }
    }

    // MARK: Presenting

    private func setPresenting(_ app: String?) {
        guard app != presenting else { return }
        presenting = app
        hub?.setRemoteState(accessibility: trusted, presenting: app)
    }

    func allowKeynoteDetection() {
        presentingMonitor.requestKeynoteAutomation()
        keynoteAutomation = presentingMonitor.automationState
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { self?.keynoteAutomation = self?.presentingMonitor.automationState ?? .notInstalled }
        }
    }

    // MARK: Session

    func sessionEnded() { router.sessionEnded() }

    /// A Settings preview of the laser: sweeps a figure of eight for two seconds. Draws an overlay only; posts no input.
    func previewLaser() { laserOverlay.preview() }

    // MARK: Fixtures

    func setFixture(trusted: Bool, cardRequested: Bool = false, presenting: String? = nil,
                    keynote: PresentingMonitor.AutomationState = .notInstalled) {
        self.trusted = trusted
        self.cardRequested = cardRequested
        self.presenting = presenting
        self.keynoteAutomation = keynote
    }
}

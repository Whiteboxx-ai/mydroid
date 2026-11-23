import XCTest
import CoreGraphics
@testable import Mydroid
@testable import MydroidCore

// App-layer logic with fakes. Nothing here posts an input event, locks, sleeps, rings, changes the volume or scans for Bluetooth.

private final class FakePoster: SyntheticEventPoster, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [SyntheticEvent] = []
    var events: [SyntheticEvent] { lock.lock(); defer { lock.unlock() }; return _events }
    func post(_ e: SyntheticEvent) { lock.lock(); _events.append(e); lock.unlock() }
    func cursorLocation() -> CGPoint { CGPoint(x: 300, y: 300) }
    func screenFrames() -> [CGRect] { [CGRect(x: 0, y: 0, width: 1440, height: 900)] }
}

private final class FakeChecker: AccessibilityChecking, @unchecked Sendable {
    var isTrusted: Bool
    init(_ t: Bool) { isTrusted = t }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0; private var flags: [Bool] = []
    func hit() { lock.lock(); n += 1; lock.unlock() }
    func push(_ b: Bool) { lock.lock(); flags.append(b); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    var pushed: [Bool] { lock.lock(); defer { lock.unlock() }; return flags }
}

final class RemoteRouterTests: XCTestCase {
    private func waitFor(_ cond: @autoclosure () -> Bool, timeout: TimeInterval = 2) {
        let end = Date().addingTimeInterval(timeout)
        while !cond(), Date() < end { Thread.sleep(forTimeInterval: 0.01) }
    }

    func testInputReachesThePosterOnlyWhenAllowed() {
        let poster = FakePoster()
        let checker = FakeChecker(true)
        let router = RemoteInputRouter(poster: poster, checker: checker)
        router.refresh()
        router.receive(.move(dx: 5, dy: 5))
        router.receive(.click(.left, count: 1))
        waitFor(poster.events.count >= 3)
        XCTAssertEqual(poster.events, [
            .mouseMove(CGPoint(x: 305, y: 305), dx: 5, dy: 5),
            .mouseButton(CGPoint(x: 305, y: 305), .left, down: true, clickCount: 1),
            .mouseButton(CGPoint(x: 305, y: 305), .left, down: false, clickCount: 1)])
    }

    func testWithoutAccessibilityNothingIsPostedAndTheCardIsRequestedAtMostEveryTwoSeconds() {
        let poster = FakePoster()
        let checker = FakeChecker(false)
        let router = RemoteInputRouter(poster: poster, checker: checker)
        let asked = Flag()
        router.onNeedsPermission = { asked.hit() }
        router.refresh()
        for i in 0..<50 { router.receive(.move(dx: Double(i), dy: 0)) }
        router.receive(.key("a", mods: []))
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertTrue(poster.events.isEmpty, "no permission: not one event is posted")
        XCTAssertEqual(asked.count, 1, "asked once for the whole burst")
    }

    func testGrantingWhileRunningIsNoticedAndSomeInputFlows() {
        let poster = FakePoster()
        let checker = FakeChecker(false)
        let router = RemoteInputRouter(poster: poster, checker: checker)
        let changed = Flag()
        router.onTrustChanged = { changed.hit() }
        router.refresh()
        checker.isTrusted = true
        router.refresh()                                   // the app's re-check (activation, or the 2 s poll)
        XCTAssertEqual(changed.count, 1)
        router.receive(.key("x", mods: []))
        waitFor(!poster.events.isEmpty)
        XCTAssertEqual(poster.events, [.unicode("x", flags: [])])
    }

    func testRevokingWhileRunningStopsInputWithinASecond() {
        let poster = FakePoster()
        let checker = FakeChecker(true)
        let router = RemoteInputRouter(poster: poster, checker: checker)
        router.refresh()
        router.receive(.media(.mute))
        waitFor(poster.events.count == 2)
        checker.isTrusted = false
        Thread.sleep(forTimeInterval: 1.1)                  // the cached answer expires
        router.receive(.media(.mute))
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(poster.events.count, 2)
    }

    func testLaserWorksWithoutPermissionAndReportsOnOff() {
        let poster = FakePoster()
        let router = RemoteInputRouter(poster: poster, checker: FakeChecker(false))
        let seen = Flag()
        router.onLaser = { seen.push($0) }
        let v0 = router.laser.get().version
        router.receive(.laser(on: true, x: 0.3, y: 0.6))
        router.receive(.laser(on: true, x: 0.31, y: 0.61))
        router.receive(.laser(on: false, x: 0.31, y: 0.61))
        XCTAssertEqual(seen.pushed, [true, false], "only the changes of on/off")
        XCTAssertEqual(router.laser.get().point, CGPoint(x: 0.31, y: 0.61))
        XCTAssertEqual(router.laser.get().version, v0 + 3)
        XCTAssertTrue(poster.events.isEmpty)
    }

    func testEndingTheSessionReleasesADragAndHidesTheLaser() {
        let poster = FakePoster()
        let router = RemoteInputRouter(poster: poster, checker: FakeChecker(true))
        router.refresh()
        let seen = Flag()
        router.onLaser = { seen.push($0) }
        router.receive(.down(.left))
        router.receive(.laser(on: true, x: 0.5, y: 0.5))
        router.sessionEnded()
        waitFor(poster.events.count >= 2)
        XCTAssertEqual(poster.events.last, .mouseButton(CGPoint(x: 300, y: 300), .left, down: false, clickCount: 1), "the button is let go")
        XCTAssertEqual(seen.pushed, [true, false])
    }
}

@MainActor
final class RingControllerTests: XCTestCase {
    final class Sound: RingSounding { var starts = 0, stops = 0; func start() { starts += 1 }; func stop() { stops += 1 } }
    final class Volume: VolumeControlling {
        var boosts = 0; var restored: [VolumeSnapshot] = []
        func boost() -> VolumeSnapshot? { boosts += 1; return VolumeSnapshot(volume: 0.3, muted: true) }
        func restore(_ s: VolumeSnapshot) { restored.append(s) }
    }
    final class Panel: RingPanelPresenting {
        var shown = 0, hidden = 0; var stop: (() -> Void)?
        func show(stop: @escaping () -> Void) { shown += 1; self.stop = stop }
        func hide() { hidden += 1 }
    }
    final class Waker: DisplayWaking { var wakes = 0; func wake() { wakes += 1 } }

    func make(duration: TimeInterval = 60) -> (RingController, Sound, Volume, Panel, Waker) {
        let s = Sound(), v = Volume(), p = Panel(), w = Waker()
        return (RingController(sound: s, volume: v, panel: p, waker: w, duration: duration), s, v, p, w)
    }

    func testRingStartsLoudAndStopRestoresEverything() {
        let (r, sound, vol, panel, waker) = make()
        r.start()
        XCTAssertTrue(r.isRinging)
        XCTAssertEqual(sound.starts, 1); XCTAssertEqual(vol.boosts, 1); XCTAssertEqual(panel.shown, 1); XCTAssertEqual(waker.wakes, 1)
        XCTAssertNotNil(r.endsAt)
        r.start()                                              // asked again while ringing: no second sound or panel, the volume isn't boosted twice
        XCTAssertEqual(sound.starts, 1); XCTAssertEqual(vol.boosts, 1); XCTAssertEqual(panel.shown, 1)
        r.stop()
        XCTAssertFalse(r.isRinging)
        XCTAssertEqual(sound.stops, 1)
        XCTAssertEqual(vol.restored, [VolumeSnapshot(volume: 0.3, muted: true)], "the volume and mute state from before are put back")
        XCTAssertEqual(panel.hidden, 1)
        r.stop()                                               // idempotent
        XCTAssertEqual(sound.stops, 1); XCTAssertEqual(vol.restored.count, 1); XCTAssertEqual(panel.hidden, 1)
    }

    func testStopButtonOnThePanelStops() {
        let (r, sound, _, panel, _) = make()
        r.start()
        panel.stop?()
        XCTAssertFalse(r.isRinging)
        XCTAssertEqual(sound.stops, 1)
    }

    func testAutoStopsAfterTheDuration() async throws {
        let (r, sound, vol, panel, _) = make(duration: 0.2)
        r.start()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(r.isRinging, "stops by itself")
        XCTAssertEqual(sound.stops, 1); XCTAssertEqual(vol.restored.count, 1); XCTAssertEqual(panel.hidden, 1)
    }

    func testTheRealDurationIsSixtySeconds() {
        XCTAssertEqual(RingController.defaultDuration, 60)
    }

    func testPhoneCanStopItFromAnyThread() async throws {
        let (r, sound, _, _, _) = make()
        r.start()
        DispatchQueue.global().async { r.stopRinging() }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(r.isRinging)
        XCTAssertEqual(sound.stops, 1)
    }
}

@MainActor
final class WalkAwayControllerTests: XCTestCase {
    final class Scanner: BleScanning {
        var onSample: ((Int) -> Void)?; var onState: ((BluetoothStatus) -> Void)?
        var started: [String] = []; var stops = 0
        func start(serviceUUID: String) { started.append(serviceUUID) }
        func stop() { stops += 1 }
    }
    final class Idle: IdleTimeSource { var seconds: TimeInterval? = 600; func secondsSinceInput() -> TimeInterval? { seconds } }
    final class Waker: DisplayWaking { var wakes = 0; func wake() { wakes += 1 } }
    final class Actions: MacActionPerforming, @unchecked Sendable {
        private let lock = NSLock(); private var log: [MacAction] = []
        var performed: [MacAction] { lock.lock(); defer { lock.unlock() }; return log }
        func perform(_ action: MacAction, completion: @escaping @Sendable (MacActionResult) -> Void) {
            lock.lock(); log.append(action); lock.unlock(); completion(.success)
        }
        func listShortcuts(completion: @escaping @Sendable (Result<[String], MacActionFailure>) -> Void) { completion(.success([])) }
    }

    var clock = Date(timeIntervalSince1970: 50_000)
    let scanner = Scanner(), idle = Idle(), waker = Waker(), actions = Actions()
    var locked = false
    let uuid = "077c9215-b54a-4afb-970e-3efc5edd6c5d"

    func make() -> WalkAwayController {
        WalkAwayController(scanner: scanner, idle: idle, waker: waker, actions: { [actions] in actions }, isLocked: { [unowned self] in self.locked },
                           now: { [unowned self] in self.clock })
    }

    /// One second at a time: a sample (if any) and a tick.
    func run(_ c: WalkAwayController, rssi: Int?, seconds: Int) {
        for _ in 0..<seconds {
            clock += 1
            if let rssi { c.sample(rssi) }
            c.tick()
        }
    }

    func testOffByDefaultNothingScans() {
        let c = make()
        c.configure(enabled: false, phoneUUID: uuid, sensitivity: .medium, wakeOnReturn: true)
        XCTAssertFalse(c.active)
        XCTAssertTrue(scanner.started.isEmpty)
        c.configure(enabled: true, phoneUUID: nil, sensitivity: .medium, wakeOnReturn: true)
        XCTAssertFalse(c.active, "no paired phone, nothing to scan for")
        XCTAssertTrue(scanner.started.isEmpty)
    }

    func testScansForThePhonesUuidWhileOnAndStopsWhenOff() {
        let c = make()
        c.configure(enabled: true, phoneUUID: uuid, sensitivity: .medium, wakeOnReturn: true)
        XCTAssertTrue(c.active)
        XCTAssertEqual(scanner.started, [uuid])
        c.configure(enabled: true, phoneUUID: uuid, sensitivity: .far, wakeOnReturn: true)
        XCTAssertEqual(scanner.started, [uuid], "changing sensitivity doesn't restart the scan")
        c.configure(enabled: false, phoneUUID: uuid, sensitivity: .far, wakeOnReturn: true)
        XCTAssertFalse(c.active)
        XCTAssertEqual(scanner.stops, 1)
        XCTAssertEqual(c.signal, .none)
    }

    func testWalkingAwayLocksThenSleepsTheDisplayAndReturningWakesIt() async throws {
        let c = make()
        c.configure(enabled: true, phoneUUID: uuid, sensitivity: .medium, wakeOnReturn: true)
        run(c, rssi: -50, seconds: 6)
        XCTAssertEqual(c.signal, .strong)
        run(c, rssi: -92, seconds: 25)
        XCTAssertEqual(actions.performed.first, .lock)
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(actions.performed, [.lock, .displaySleep], "locked once, then the display was put to sleep, both through the action layer")
        XCTAssertEqual(waker.wakes, 0)
        run(c, rssi: -50, seconds: 30)
        XCTAssertEqual(waker.wakes, 1, "back: the display is woken (the lock screen still wants a password)")
        XCTAssertEqual(actions.performed.count, 2, "nothing else is ever performed: there is no unlock")
    }

    func testReturnDoesNotWakeWhenTheOptionIsOff() {
        let c = make()
        c.configure(enabled: true, phoneUUID: uuid, sensitivity: .medium, wakeOnReturn: false)
        run(c, rssi: -50, seconds: 6)
        run(c, rssi: -92, seconds: 25)
        run(c, rssi: -50, seconds: 30)
        XCTAssertEqual(waker.wakes, 0)
    }

    func testAMacInUseIsLeftAlone() {
        let c = make()
        c.configure(enabled: true, phoneUUID: uuid, sensitivity: .medium, wakeOnReturn: true)
        idle.seconds = 4
        run(c, rssi: -50, seconds: 6)
        run(c, rssi: -92, seconds: 40)
        XCTAssertTrue(actions.performed.isEmpty, "someone is typing")
        idle.seconds = 25
        run(c, rssi: -92, seconds: 2)
        XCTAssertEqual(actions.performed.first, .lock, "once the Mac goes quiet it is locked")
    }

    func testAnAlreadyLockedScreenIsNotLockedAgain() {
        let c = make()
        c.configure(enabled: true, phoneUUID: uuid, sensitivity: .medium, wakeOnReturn: true)
        run(c, rssi: -50, seconds: 6)
        locked = true
        run(c, rssi: -92, seconds: 40)
        XCTAssertTrue(actions.performed.isEmpty)
    }

    func testTheMeterFollowsTheSignal() {
        let c = make()
        c.configure(enabled: true, phoneUUID: uuid, sensitivity: .medium, wakeOnReturn: true)
        XCTAssertEqual(c.signal, .none)
        run(c, rssi: -50, seconds: 5)
        XCTAssertEqual(c.signal, .strong)
        XCTAssertNotNil(c.rssi)
        clock += 30
        c.tick()
        XCTAssertEqual(c.signal, .none, "not heard for a while")
    }

    func testSettingsTabsAndPrefsDefaults() throws {
        XCTAssertTrue(SettingsTab.allCases.contains(.remote))
        XCTAssertTrue(SettingsTab.allCases.contains(.walkAway))
        XCTAssertEqual(SettingsTab.walkAway.title, "Walk-away lock")
        let d = UserDefaults(suiteName: "mydroid.test.\(UUID().uuidString)")!
        d.set(Data(#"{"showBatteryInMenuBar":true}"#.utf8), forKey: MacPrefs.key)
        let p = MacPrefs.load(d)
        XCTAssertTrue(p.showBatteryInMenuBar)
        XCTAssertEqual(p.walkAwaySensitivity, .medium)
        XCTAssertTrue(p.walkAwayWake, "wake on return is on by default")
        XCTAssertFalse(p.walkAwayNoteSeen)
        XCTAssertEqual(p.laserColor, .red)
        XCTAssertFalse(p.reverseScroll)
        var q = MacPrefs(); q.walkAwaySensitivity = .far; q.laserColor = .green; q.reverseScroll = true
        q.save(d)
        XCTAssertEqual(MacPrefs.load(d), q)
        XCTAssertFalse(HubState().settings.walkAway, "walk-away is off by default")
    }
}

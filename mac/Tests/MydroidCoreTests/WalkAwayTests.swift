import XCTest
@testable import MydroidCore

/// Drives the walk-away machine with made-up RSSI samples and a made-up clock. Nothing touches Bluetooth or the lock.
final class WalkAwayMachineTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 10_000)
    var m = WalkAwayMachine(sensitivity: .medium)       // threshold -75, return above -67

    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    /// Feeds one sample per second at `rssi` from `from` to `to` (seconds), ticking after each. Returns the actions, with times.
    @discardableResult
    func run(_ rssi: Int?, from: Int, to: Int, idle: TimeInterval? = 600, locked: Bool = false) -> [(Int, WalkAwayMachine.Action)] {
        var out: [(Int, WalkAwayMachine.Action)] = []
        for s in from...to {
            if let rssi { m.ingest(rssi: rssi, at: at(Double(s))) }
            if let a = m.tick(now: at(Double(s)), idle: idle, screenLocked: locked) { out.append((s, a)) }
        }
        return out
    }

    func testThresholdsPerSensitivity() {
        XCTAssertEqual(WalkAwaySensitivity.near.threshold, -65)
        XCTAssertEqual(WalkAwaySensitivity.medium.threshold, -75)
        XCTAssertEqual(WalkAwaySensitivity.far.threshold, -85)
    }

    func testNothingHappensBeforeThePhoneHasEverBeenSeen() {
        XCTAssertNil(m.tick(now: at(500), idle: 600, screenLocked: false))
        XCTAssertEqual(m.phase, .waiting)
        XCTAssertEqual(m.signal(now: at(500)), .none)
    }

    func testSmoothingIgnoresASingleDip() {
        run(-55, from: 0, to: 10)
        m.ingest(rssi: -95, at: at(11))                 // one noisy reading
        XCTAssertGreaterThan(m.smoothed!, -75, "one outlier doesn't push the average past the threshold")
        XCTAssertNil(m.tick(now: at(12), idle: 600, screenLocked: false))
        run(-55, from: 12, to: 40)
        XCTAssertEqual(m.phase, .near)
    }

    func testWeakSignalMustLastEightSecondsThenLocksOnce() {
        run(-55, from: 0, to: 5)
        let acts = run(-90, from: 6, to: 40)
        XCTAssertEqual(acts.count, 1, "exactly one lock, however long the phone stays away")
        XCTAssertEqual(acts[0].1, .lock)
        // The average has to cross -75 first (a couple of samples), then 8 s below it.
        XCTAssertGreaterThanOrEqual(acts[0].0, 6 + 8)
        XCTAssertLessThanOrEqual(acts[0].0, 6 + 8 + 4)
        XCTAssertEqual(m.phase, .away)
    }

    func testNotSeenForTwelveSecondsLocks() {
        run(-50, from: 0, to: 10)
        var acts: [(Int, WalkAwayMachine.Action)] = []
        for s in 11...40 { if let a = m.tick(now: at(Double(s)), idle: 600, screenLocked: false) { acts.append((s, a)) } }
        XCTAssertEqual(acts.map(\.1), [.lock])
        XCTAssertEqual(acts[0].0, 22, "last heard at 10 s, 12 s of silence")
    }

    func testSignalLevels() {
        run(-55, from: 0, to: 6)
        XCTAssertEqual(m.signal(now: at(6)), .strong)
        var weak = WalkAwayMachine(sensitivity: .medium)
        for s in 0...6 { weak.ingest(rssi: -88, at: at(Double(s))) }
        XCTAssertEqual(weak.signal(now: at(6)), .weak)
        var mid = WalkAwayMachine(sensitivity: .medium)
        for s in 0...6 { mid.ingest(rssi: -72, at: at(Double(s))) }
        XCTAssertEqual(mid.signal(now: at(6)), .medium)
        XCTAssertEqual(mid.signal(now: at(60)), .none, "stale")
        XCTAssertEqual(WalkAwayMachine.meterFraction(rssi: -100), 0)
        XCTAssertEqual(WalkAwayMachine.meterFraction(rssi: -45), 1)
        XCTAssertEqual(WalkAwayMachine.meterFraction(rssi: -72.5), 0.5, accuracy: 0.001)
    }

    func testAMacInUseIsNotLockedButIsOnceItGoesQuiet() {
        run(-50, from: 0, to: 5)
        // Phone gone weak, but someone is typing (idle 3 s) the whole time.
        XCTAssertTrue(run(-92, from: 6, to: 40, idle: 3).isEmpty, "in use: no lock")
        XCTAssertEqual(m.phase, .away)
        XCTAssertTrue(m.isLockPending, "it will look again")
        // Still in use just under the limit.
        XCTAssertTrue(run(-92, from: 41, to: 45, idle: 19.9).isEmpty)
        // The user stops: idle reaches 20 s and the phone is still away.
        let acts = run(-92, from: 46, to: 50, idle: 20)
        XCTAssertEqual(acts.map(\.1), [.lock])
        XCTAssertEqual(acts.first?.0, 46)
    }

    func testUnknownIdleCountsAsIdle() {
        run(-50, from: 0, to: 5)
        XCTAssertEqual(run(-92, from: 6, to: 30, idle: nil).map(\.1), [.lock])
    }

    func testDoesNotLockAnAlreadyLockedScreenAndDoesNotWakeItLater() {
        run(-50, from: 0, to: 5)
        XCTAssertTrue(run(-92, from: 6, to: 40, locked: true).isEmpty)
        XCTAssertFalse(m.isLockPending)
        // The phone comes back: we didn't lock it, so there's nothing to wake.
        XCTAssertTrue(run(-50, from: 41, to: 60).isEmpty)
        XCTAssertEqual(m.phase, .near)
    }

    func testReturnNeedsEightDecibelsOverThresholdForThreeSeconds() {
        run(-50, from: 0, to: 5)
        run(-92, from: 6, to: 30)
        XCTAssertEqual(m.phase, .away)
        // Just above the threshold is not enough (hysteresis): -72 is over -75 but under -67.
        XCTAssertTrue(run(-72, from: 31, to: 70).isEmpty)
        XCTAssertEqual(m.phase, .away)
        // Strong again.
        let acts = run(-50, from: 71, to: 100)
        XCTAssertEqual(acts.map(\.1), [.returned])
        XCTAssertEqual(m.phase, .near)
        // The average has to climb past -67 first, then stay there 3 s.
        XCTAssertGreaterThanOrEqual(acts[0].0, 71 + 3)
        XCTAssertLessThanOrEqual(acts[0].0, 71 + 3 + 6)
    }

    func testReturnAfterALongSilenceIsQuick() {
        run(-50, from: 0, to: 5)
        for s in 6...40 { _ = m.tick(now: at(Double(s)), idle: 600, screenLocked: false) }      // vanished: locked at 18 s
        XCTAssertEqual(m.phase, .away)
        // The first strong sample re-seeds the average instead of blending with a 40-second-old one.
        let acts = run(-50, from: 41, to: 50)
        XCTAssertEqual(acts.map(\.1), [.returned])
        XCTAssertLessThanOrEqual(acts[0].0, 41 + 3 + 1)
    }

    func testPhoneReturningWhileLockWasStillSuppressedWakesNothing() {
        run(-50, from: 0, to: 5)
        XCTAssertTrue(run(-92, from: 6, to: 30, idle: 2).isEmpty)       // away, but in use
        XCTAssertTrue(run(-50, from: 31, to: 60, idle: 2).isEmpty)      // back before we ever locked
        XCTAssertEqual(m.phase, .near)
        XCTAssertFalse(m.isLockPending)
    }

    func testNoRelockUntilThePhoneHasComeBack() {
        run(-50, from: 0, to: 5)
        XCTAssertEqual(run(-92, from: 6, to: 30).count, 1)
        // The user unlocks by hand with the phone still away: no second lock.
        XCTAssertTrue(run(-92, from: 31, to: 120).isEmpty)
        // Phone returns, then leaves again: now it locks again.
        XCTAssertEqual(run(-50, from: 121, to: 140).map(\.1), [.returned])
        XCTAssertEqual(run(-92, from: 141, to: 170).map(\.1), [.lock])
    }

    func testResetForgetsEverything() {
        run(-50, from: 0, to: 5)
        run(-92, from: 6, to: 30)
        m.reset()
        XCTAssertEqual(m.phase, .waiting)
        XCTAssertNil(m.smoothed)
        XCTAssertNil(m.tick(now: at(500), idle: 600, screenLocked: false), "after a reset the phone must be seen again before anything can happen")
    }

    func testSensitivityChangesTheThreshold() {
        var near = WalkAwayMachine(sensitivity: .near)
        var far = WalkAwayMachine(sensitivity: .far)
        var acts = (near: 0, far: 0)
        for s in 0...40 {
            near.ingest(rssi: -72, at: at(Double(s))); far.ingest(rssi: -72, at: at(Double(s)))
            if near.tick(now: at(Double(s)), idle: 600, screenLocked: false) == .lock { acts.near += 1 }
            if far.tick(now: at(Double(s)), idle: 600, screenLocked: false) == .lock { acts.far += 1 }
        }
        XCTAssertEqual(acts.near, 1, "-72 is weak for Near (threshold -65)")
        XCTAssertEqual(acts.far, 0, "-72 is fine for Far (threshold -85)")
    }

    func testBadReadingsAreIgnored() {
        m.ingest(rssi: 127, at: at(0))
        m.ingest(rssi: 0, at: at(1))
        XCTAssertNil(m.smoothed)
        XCTAssertEqual(m.phase, .waiting)
    }
}

final class PresentingDetectorTests: XCTestCase {
    typealias W = FrontWindow
    func detect(_ bundle: String?, _ name: String = "App", _ windows: [W], keynote: Bool? = nil) -> String? {
        PresentingDetector.presenting(bundleID: bundle, appName: name, windows: windows, keynotePlaying: keynote)
    }

    func testKeynoteUsesItsOwnAnswerWhenKnown() {
        XCTAssertEqual(detect("com.apple.iWork.Keynote", "Keynote", [], keynote: true), "Keynote")
        XCTAssertNil(detect("com.apple.iWork.Keynote", "Keynote", [W(title: "Deck", fullScreen: true)], keynote: false), "full-screen editing isn't presenting")
    }

    func testKeynoteFallsBackToAFullScreenWindow() {
        XCTAssertEqual(detect("com.apple.iWork.Keynote", "Keynote", [W(title: "", fullScreen: true)]), "Keynote")
        XCTAssertNil(detect("com.apple.iWork.Keynote", "Keynote", [W(title: "Deck", fullScreen: false)]))
    }

    func testPowerPointSlideShowTitle() {
        XCTAssertEqual(detect("com.microsoft.Powerpoint", "PowerPoint", [W(title: "PowerPoint Slide Show - Q3.pptx", fullScreen: true)]), "PowerPoint")
        XCTAssertNil(detect("com.microsoft.Powerpoint", "PowerPoint", [W(title: "Q3.pptx", fullScreen: false)]))
    }

    func testPreviewSlideshowNeedsFullScreenAndTheWord() {
        XCTAssertEqual(detect("com.apple.Preview", "Preview", [W(title: "Slideshow", fullScreen: true)]), "Preview")
        XCTAssertNil(detect("com.apple.Preview", "Preview", [W(title: "Slideshow notes.pdf", fullScreen: false)]))
        XCTAssertNil(detect("com.apple.Preview", "Preview", [W(title: "report.pdf", fullScreen: true)]))
    }

    func testBrowsersPresentingGoogleSlidesOrPowerPointOnline() {
        XCTAssertEqual(detect("com.google.Chrome", "Google Chrome", [W(title: "Roadmap - Google Slides", fullScreen: true)]), "Google Chrome")
        XCTAssertEqual(detect("com.apple.Safari", "Safari", [W(title: "Deck.pptx - PowerPoint", fullScreen: true)]), "Safari")
        XCTAssertNil(detect("com.google.Chrome", "Google Chrome", [W(title: "Roadmap - Google Slides", fullScreen: false)]), "editing in a window")
        XCTAssertNil(detect("com.google.Chrome", "Google Chrome", [W(title: "YouTube", fullScreen: true)]))
    }

    func testAnyAppFullScreenWithSlideShowInTheTitle() {
        XCTAssertEqual(detect("org.example.Viewer", "Viewer", [W(title: "Slide Show \u{2014} talk.odp", fullScreen: true)]), "Viewer")
        XCTAssertNil(detect("org.example.Viewer", "Viewer", [W(title: "talk.odp", fullScreen: true)]))
        XCTAssertNil(detect(nil, "", [W(title: "Slideshow", fullScreen: true)]))
    }

    func testCandidates() {
        XCTAssertTrue(PresentingDetector.isCandidate(bundleID: "com.apple.iWork.Keynote"))
        XCTAssertTrue(PresentingDetector.isCandidate(bundleID: "com.google.Chrome"))
        XCTAssertFalse(PresentingDetector.isCandidate(bundleID: "com.apple.finder"))
        XCTAssertFalse(PresentingDetector.isCandidate(bundleID: nil))
    }
}

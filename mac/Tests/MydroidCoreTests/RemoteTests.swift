import XCTest
import CoreGraphics
@testable import MydroidCore

/// Records what would be posted. Nothing here ever reaches the system.
final class RecordingPoster: SyntheticEventPoster {
    var events: [SyntheticEvent] = []
    var cursor = CGPoint(x: 100, y: 100)
    var screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
    func post(_ e: SyntheticEvent) { events.append(e) }
    func cursorLocation() -> CGPoint { cursor }
    func screenFrames() -> [CGRect] { screens }
}

final class KeyMapTests: XCTestCase {
    func testNamedKeysMatchCarbonVirtualKeycodes() {
        let expected: [String: UInt16] = [
            "left": 123, "right": 124, "down": 125, "up": 126,
            "enter": 36, "escape": 53, "space": 49, "tab": 48, "backspace": 51, "delete": 117,
            "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        ]
        for (name, code) in expected { XCTAssertEqual(KeyMap.keyCode(named: name), code, name) }
        XCTAssertEqual(Set(expected.values).count, expected.count, "no two names share a keycode")
        XCTAssertNil(KeyMap.keyCode(named: "f13"))
        XCTAssertNil(KeyMap.keyCode(named: "nonsense"))
        XCTAssertEqual(KeyMap.keyCode(named: "LEFT"), 123, "names are case-insensitive")
    }

    func testEveryProtocolNameIsMapped() {
        let listed = "left right up down enter escape space tab backspace delete home end pageup pagedown f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12"
        for n in listed.split(separator: " ") { XCTAssertNotNil(KeyMap.keyCode(named: String(n)), "\(n)") }
    }

    func testAnsiPositions() {
        XCTAssertEqual(KeyMap.ansiKeyCode(for: "a"), 0)
        XCTAssertEqual(KeyMap.ansiKeyCode(for: "C"), 8)
        XCTAssertEqual(KeyMap.ansiKeyCode(for: "q"), 12)
        XCTAssertEqual(KeyMap.ansiKeyCode(for: "0"), 29)
        XCTAssertEqual(KeyMap.ansiKeyCode(for: "["), 33)
        XCTAssertNil(KeyMap.ansiKeyCode(for: "\u{20AC}"))
    }

    func testPlans() {
        // Names keep their modifiers.
        XCTAssertEqual(KeyMap.plan(key: "left", mods: [.shift]), .code(123, [.shift]))
        // A chord uses the key position, so cmd-c is the C key.
        XCTAssertEqual(KeyMap.plan(key: "c", mods: [.command]), .code(8, [.command]))
        XCTAssertEqual(KeyMap.plan(key: "Z", mods: [.command]), .code(6, [.command, .shift]))
        // Plain characters are typed as Unicode.
        XCTAssertEqual(KeyMap.plan(key: "a", mods: []), .unicode("a", []))
        XCTAssertEqual(KeyMap.plan(key: "\u{00E9}", mods: []), .unicode("\u{00E9}", []))
        XCTAssertEqual(KeyMap.plan(key: "a", mods: [.shift]), .unicode("A", [.shift]), "shift with a letter types the capital")
        XCTAssertEqual(KeyMap.plan(key: "\u{20AC}", mods: [.command]), .unicode("\u{20AC}", [.command]), "no ANSI key: falls back to Unicode")
        // Whitespace characters are real keys.
        XCTAssertEqual(KeyMap.plan(key: " ", mods: []), .code(49, []))
        XCTAssertEqual(KeyMap.plan(key: "\n", mods: []), .code(36, []))
        XCTAssertEqual(KeyMap.plan(key: "\t", mods: []), .code(48, []))
        // Junk.
        XCTAssertNil(KeyMap.plan(key: "nope", mods: []))
        XCTAssertNil(KeyMap.plan(key: "", mods: []))
        XCTAssertNil(KeyMap.plan(key: "\u{07}", mods: []), "control characters are refused")
    }

    func testModifierNames() {
        XCTAssertEqual(ModifierFlags(names: ["cmd", "shift", "option", "ctrl"]), [.command, .shift, .option, .control])
        XCTAssertEqual(ModifierFlags(names: ["CMD", "bogus"]), [.command])
        // The raw values are CGEventFlags, so the real poster can copy them.
        XCTAssertEqual(ModifierFlags.command.rawValue, CGEventFlags.maskCommand.rawValue)
        XCTAssertEqual(ModifierFlags.shift.rawValue, CGEventFlags.maskShift.rawValue)
        XCTAssertEqual(ModifierFlags.option.rawValue, CGEventFlags.maskAlternate.rawValue)
        XCTAssertEqual(ModifierFlags.control.rawValue, CGEventFlags.maskControl.rawValue)
    }

    func testMediaKeyTypes() {
        XCTAssertEqual(MediaKey(action: "playpause")?.nxKeyType, 16)
        XCTAssertEqual(MediaKey(action: "next")?.nxKeyType, 17)
        XCTAssertEqual(MediaKey(action: "prev")?.nxKeyType, 18)
        XCTAssertEqual(MediaKey(action: "volup")?.nxKeyType, 0)
        XCTAssertEqual(MediaKey(action: "voldown")?.nxKeyType, 1)
        XCTAssertEqual(MediaKey(action: "mute")?.nxKeyType, 7)
        XCTAssertNil(MediaKey(action: "eject"))
    }
}

final class RemoteInputParseTests: XCTestCase {
    func parse(_ type: String, _ f: [String: Any] = [:]) -> RemoteInput? { RemoteInput(message: Message(type, f)) }

    func testParsesEveryType() {
        XCTAssertEqual(parse("in.move", ["dx": 3.5, "dy": -2]), .move(dx: 3.5, dy: -2))
        XCTAssertEqual(parse("in.scroll", ["dx": 0, "dy": 12.25, "phase": "momentum"]), .scroll(dx: 0, dy: 12.25, phase: .momentum))
        XCTAssertEqual(parse("in.scroll", ["dy": 4]), .scroll(dx: 0, dy: 4, phase: nil))
        XCTAssertEqual(parse("in.click", ["button": "right", "count": 1]), .click(.right, count: 1))
        XCTAssertEqual(parse("in.click", ["button": "left", "count": 2]), .click(.left, count: 2))
        XCTAssertEqual(parse("in.click", [:]), .click(.left, count: 1))
        XCTAssertEqual(parse("in.down", ["button": "left"]), .down(.left))
        XCTAssertEqual(parse("in.up", ["button": "middle"]), .up(.middle))
        XCTAssertEqual(parse("in.key", ["key": "right"]), .key("right", mods: []))
        XCTAssertEqual(parse("in.key", ["key": "c", "mods": ["cmd", "shift"]]), .key("c", mods: [.command, .shift]))
        XCTAssertEqual(parse("in.text", ["text": "hello"]), .text("hello"))
        XCTAssertEqual(parse("in.media", ["action": "volup"]), .media(.volumeUp))
        XCTAssertEqual(parse("in.laser", ["on": true, "x": 0.25, "y": 0.75]), .laser(on: true, x: 0.25, y: 0.75))
    }

    func testRejectsAndClamps() {
        XCTAssertNil(parse("in.key", ["key": "bogus"]))
        XCTAssertNil(parse("in.key", [:]))
        XCTAssertNil(parse("in.text", ["text": ""]))
        XCTAssertNil(parse("in.media", ["action": "eject"]))
        XCTAssertNil(parse("in.nothing"))
        XCTAssertEqual(parse("in.click", ["count": 9]), .click(.left, count: 3))
        XCTAssertEqual(parse("in.click", ["count": 0]), .click(.left, count: 1))
        XCTAssertEqual(parse("in.move", ["dx": 1e9, "dy": -1e9]), .move(dx: RemoteInput.maxDelta, dy: -RemoteInput.maxDelta))
        XCTAssertEqual(parse("in.laser", ["on": true, "x": 5, "y": -3]), .laser(on: true, x: 1, y: 0))
        XCTAssertEqual(parse("in.click", ["button": "bogus"]), .click(.left, count: 1))
        if case let .text(t)? = parse("in.text", ["text": String(repeating: "x", count: 10_000)]) { XCTAssertEqual(t.count, RemoteInput.maxTextLength) } else { XCTFail() }
    }

    func testIntegersAreAcceptedAsFloats() {
        XCTAssertEqual(parse("in.move", ["dx": 4, "dy": -7]), .move(dx: 4, dy: -7))
        XCTAssertEqual(parse("in.move", ["dx": true, "dy": 1]), .move(dx: 0, dy: 1), "a boolean is not a number")
    }
}

final class TextPlanTests: XCTestCase {
    func testChunksAreAtMostTwentyUnits() {
        let text = String(repeating: "a", count: 45)
        let p = TextPlan.pieces(text)
        XCTAssertEqual(p, [.chunk(String(repeating: "a", count: 20)), .chunk(String(repeating: "a", count: 20)), .chunk("aaaaa")])
    }

    func testNewlinesAndTabsBecomeKeys() {
        XCTAssertEqual(TextPlan.pieces("hi\nthere\tyou\r\nok"), [.chunk("hi"), .newline, .chunk("there"), .tab, .chunk("you"), .newline, .chunk("ok")])
        XCTAssertEqual(TextPlan.pieces(""), [])
    }

    func testClustersAreNeverSplit() {
        // Each family emoji is one Character but 8 UTF-16 units: three don't fit in 20.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        XCTAssertEqual(family.utf16.count, 8)
        let text = String(repeating: family, count: 3)         // 24 units
        let p = TextPlan.pieces(text)
        XCTAssertEqual(p.count, 2)
        for case let .chunk(s) in p { XCTAssertLessThanOrEqual(s.utf16.count, 20); XCTAssertTrue(s.count >= 1) }
        let joined = p.compactMap { if case let .chunk(s) = $0 { return s } else { return nil } }.joined()
        XCTAssertEqual(joined, text)
    }

    func testAnOversizedClusterFallsBackToScalarsWithoutLosingText() {
        let zalgo = "a" + String(repeating: "\u{0301}", count: 40)
        let p = TextPlan.pieces(zalgo)
        for case let .chunk(s) in p { XCTAssertLessThanOrEqual(s.utf16.count, 20) }
        XCTAssertEqual(p.compactMap { if case let .chunk(s) = $0 { return s } else { return nil } }.joined(), zalgo)
    }
}

final class ScreenGeometryTests: XCTestCase {
    let one = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
    // A second display to the right and a third above-left of it.
    let multi = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 1440, y: -200, width: 1920, height: 1080)]

    func testInsideIsUntouched() {
        XCTAssertEqual(ScreenGeometry.clamp(CGPoint(x: 700, y: 400), to: one), CGPoint(x: 700, y: 400))
    }

    func testClampsToEdgesOfASingleScreen() {
        XCTAssertEqual(ScreenGeometry.clamp(CGPoint(x: -50, y: 450), to: one), CGPoint(x: 0, y: 450))
        XCTAssertEqual(ScreenGeometry.clamp(CGPoint(x: 5000, y: 9000), to: one), CGPoint(x: 1439, y: 899))
        XCTAssertEqual(ScreenGeometry.clamp(CGPoint(x: 1440, y: 10), to: one), CGPoint(x: 1439, y: 10), "the far edge is outside")
    }

    func testPointerCrossesBetweenDisplays() {
        XCTAssertEqual(ScreenGeometry.clamp(CGPoint(x: 1600, y: 450), to: multi), CGPoint(x: 1600, y: 450), "on the second display")
        XCTAssertEqual(ScreenGeometry.clamp(CGPoint(x: 1500, y: -150), to: multi), CGPoint(x: 1500, y: -150), "above the first display but on the second")
        // Below the second display's top-left area but outside every screen: goes to the nearest screen.
        let q = ScreenGeometry.clamp(CGPoint(x: 100, y: -100), to: multi)
        XCTAssertEqual(q, CGPoint(x: 100, y: 0))
        XCTAssertEqual(ScreenGeometry.clamp(CGPoint(x: 9000, y: 0), to: multi), CGPoint(x: 3359, y: 0))
        XCTAssertEqual(ScreenGeometry.clamp(CGPoint(x: 5, y: 5), to: []), CGPoint(x: 5, y: 5), "no screens known: unchanged")
    }
}

final class InputInjectorTests: XCTestCase {
    var poster = RecordingPoster()
    var clock = Date(timeIntervalSince1970: 1000)
    lazy var inj = InputInjector(poster: poster, now: { [unowned self] in self.clock })

    func testRelativeMovesTrackTheirOwnPosition() {
        inj.handle(.move(dx: 10, dy: 5))
        inj.handle(.move(dx: 10, dy: 5))
        XCTAssertEqual(poster.events, [
            .mouseMove(CGPoint(x: 110, y: 105), dx: 10, dy: 5),
            .mouseMove(CGPoint(x: 120, y: 110), dx: 10, dy: 5)])
    }

    func testPointerIsReadAgainAfterAPause() {
        inj.handle(.move(dx: 10, dy: 0))
        clock += 1                                      // the user touched the real trackpad meanwhile
        poster.cursor = CGPoint(x: 500, y: 500)
        inj.handle(.move(dx: 1, dy: 1))
        XCTAssertEqual(poster.events.last, .mouseMove(CGPoint(x: 501, y: 501), dx: 1, dy: 1))
    }

    func testMovesAreClampedToTheScreens() {
        inj.handle(.move(dx: -500, dy: -500))
        XCTAssertEqual(poster.events.last, .mouseMove(CGPoint(x: 0, y: 0), dx: -500, dy: -500))
        inj.handle(.move(dx: 4000, dy: 4000))
        XCTAssertEqual(poster.events.last, .mouseMove(CGPoint(x: 1439, y: 899), dx: 4000, dy: 4000))
        poster.screens.append(CGRect(x: 1440, y: 0, width: 1000, height: 900))     // a second display appears
        inj.handle(.move(dx: 100, dy: 0))
        XCTAssertEqual(poster.events.last, .mouseMove(CGPoint(x: 1539, y: 899), dx: 100, dy: 0), "crosses onto the second display")
    }

    func testClicks() {
        poster.cursor = CGPoint(x: 50, y: 60)
        let p = CGPoint(x: 50, y: 60)
        inj.handle(.click(.left, count: 1))
        inj.handle(.click(.right, count: 1))
        XCTAssertEqual(poster.events, [
            .mouseButton(p, .left, down: true, clickCount: 1), .mouseButton(p, .left, down: false, clickCount: 1),
            .mouseButton(p, .right, down: true, clickCount: 1), .mouseButton(p, .right, down: false, clickCount: 1)])
    }

    func testDoubleClickSetsClickState() {
        poster.cursor = CGPoint(x: 50, y: 60)
        let p = CGPoint(x: 50, y: 60)
        inj.handle(.click(.left, count: 2))
        XCTAssertEqual(poster.events, [
            .mouseButton(p, .left, down: true, clickCount: 1), .mouseButton(p, .left, down: false, clickCount: 1),
            .mouseButton(p, .left, down: true, clickCount: 2), .mouseButton(p, .left, down: false, clickCount: 2)])
    }

    func testDragIsDownThenDraggedMovesThenUp() {
        poster.cursor = CGPoint(x: 200, y: 200)
        inj.handle(.down(.left))
        inj.handle(.move(dx: 5, dy: 0))
        inj.handle(.move(dx: 5, dy: 3))
        inj.handle(.up(.left))
        inj.handle(.move(dx: 1, dy: 1))
        XCTAssertEqual(poster.events, [
            .mouseButton(CGPoint(x: 200, y: 200), .left, down: true, clickCount: 1),
            .mouseDrag(CGPoint(x: 205, y: 200), .left, dx: 5, dy: 0),
            .mouseDrag(CGPoint(x: 210, y: 203), .left, dx: 5, dy: 3),
            .mouseButton(CGPoint(x: 210, y: 203), .left, down: false, clickCount: 1),
            .mouseMove(CGPoint(x: 211, y: 204), dx: 1, dy: 1)], "moves after the button is released are plain moves")
        XCTAssertTrue(inj.heldButtons.isEmpty)
    }

    func testStrayAndRepeatedButtonEventsAreIgnored() {
        inj.handle(.up(.left))
        XCTAssertTrue(poster.events.isEmpty)
        inj.handle(.down(.left)); inj.handle(.down(.left))
        XCTAssertEqual(poster.events.count, 1)
    }

    func testReleaseAllLetsGoOfADrag() {
        inj.handle(.down(.left))
        inj.handle(.down(.right))
        poster.events.removeAll()
        inj.releaseAll()
        XCTAssertEqual(poster.events.count, 2)
        XCTAssertTrue(poster.events.allSatisfy { if case .mouseButton(_, _, false, _) = $0 { return true } else { return false } })
        XCTAssertTrue(inj.heldButtons.isEmpty)
        poster.events.removeAll()
        inj.releaseAll()
        XCTAssertTrue(poster.events.isEmpty, "nothing held: nothing posted")
    }

    func testScrollPhasesAndMomentum() {
        inj.handle(.scroll(dx: 0, dy: 3, phase: nil))
        inj.handle(.scroll(dx: 0, dy: 4, phase: .began))
        inj.handle(.scroll(dx: 1, dy: 5, phase: .changed))
        inj.handle(.scroll(dx: 0, dy: 0, phase: .ended))
        inj.handle(.scroll(dx: 0, dy: 9, phase: .momentum))
        inj.handle(.scroll(dx: 0, dy: 8, phase: .momentum))
        inj.handle(.scroll(dx: 0, dy: 0, phase: .ended))
        XCTAssertEqual(poster.events, [
            .scroll(dx: 0, dy: 3, scrollPhase: 0, momentumPhase: 0),
            .scroll(dx: 0, dy: 4, scrollPhase: 1, momentumPhase: 0),       // began
            .scroll(dx: 1, dy: 5, scrollPhase: 2, momentumPhase: 0),       // changed
            .scroll(dx: 0, dy: 0, scrollPhase: 4, momentumPhase: 0),       // ended
            .scroll(dx: 0, dy: 9, scrollPhase: 0, momentumPhase: 1),       // momentum begin
            .scroll(dx: 0, dy: 8, scrollPhase: 0, momentumPhase: 2),       // momentum continue
            .scroll(dx: 0, dy: 0, scrollPhase: 0, momentumPhase: 3)])      // momentum end
    }

    func testReverseScroll() {
        inj.reverseScroll = true
        inj.handle(.scroll(dx: 2, dy: -3, phase: nil))
        XCTAssertEqual(poster.events, [.scroll(dx: -2, dy: 3, scrollPhase: 0, momentumPhase: 0)])
    }

    func testKeys() {
        inj.handle(.key("right", mods: []))
        inj.handle(.key("c", mods: [.command]))
        inj.handle(.key("x", mods: []))
        XCTAssertEqual(poster.events, [
            .key(code: 124, down: true, flags: []), .key(code: 124, down: false, flags: []),
            .key(code: 8, down: true, flags: [.command]), .key(code: 8, down: false, flags: [.command]),
            .unicode("x", flags: [])])
    }

    func testTextIsTypedInChunksWithRealReturnKeys() {
        inj.handle(.text(String(repeating: "b", count: 25) + "\nok"))
        XCTAssertEqual(poster.events, [
            .unicode(String(repeating: "b", count: 20), flags: []), .unicode("bbbbb", flags: []),
            .key(code: 36, down: true, flags: []), .key(code: 36, down: false, flags: []),
            .unicode("ok", flags: [])])
    }

    func testMediaKeysAreDownThenUp() {
        inj.handle(.media(.playPause))
        XCTAssertEqual(poster.events, [.media(.playPause, down: true), .media(.playPause, down: false)])
    }

    func testLaserIsNotInput() {
        inj.handle(.laser(on: true, x: 0.5, y: 0.5))
        XCTAssertTrue(poster.events.isEmpty)
    }
}

final class InputPipelineTests: XCTestCase {
    func testMovesAreMergedWhenTheQueueIsBusyAndOrderIsKept() {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var seen: [RemoteInput] = []
        var first = true
        let done = expectation(description: "drained")
        let pipe = InputPipeline(queue: DispatchQueue(label: "test.input")) { input in
            lock.lock(); seen.append(input); lock.unlock()
            if first { first = false; started.signal(); release.wait() }      // the first post is slow
            if case .key = input { done.fulfill() }
        }
        pipe.submit(.move(dx: 1, dy: 1))
        started.wait()
        // While that one is stuck, a burst arrives.
        pipe.submit(.move(dx: 2, dy: 0))
        pipe.submit(.move(dx: 3, dy: 0))
        pipe.submit(.move(dx: 4, dy: 1))
        pipe.submit(.click(.left, count: 1))
        pipe.submit(.move(dx: 5, dy: 5))
        pipe.submit(.move(dx: 5, dy: 5))
        pipe.submit(.key("x", mods: []))
        release.signal()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(seen, [
            .move(dx: 1, dy: 1),
            .move(dx: 9, dy: 1),                    // three queued moves became one
            .click(.left, count: 1),                // a click is never merged, and nothing moves across it
            .move(dx: 10, dy: 10),
            .key("x", mods: [])])
    }

    func testScrollMergesOnlyWithinAPhase() {
        XCTAssertEqual(InputPipeline.merge(.scroll(dx: 0, dy: 1, phase: .changed), .scroll(dx: 0, dy: 2, phase: .changed)),
                       .scroll(dx: 0, dy: 3, phase: .changed))
        XCTAssertEqual(InputPipeline.merge(.scroll(dx: 0, dy: 1, phase: .momentum), .scroll(dx: 1, dy: 2, phase: .momentum)),
                       .scroll(dx: 1, dy: 3, phase: .momentum))
        XCTAssertNil(InputPipeline.merge(.scroll(dx: 0, dy: 1, phase: .began), .scroll(dx: 0, dy: 2, phase: .began)))
        XCTAssertNil(InputPipeline.merge(.scroll(dx: 0, dy: 1, phase: .changed), .scroll(dx: 0, dy: 2, phase: .ended)))
        XCTAssertNil(InputPipeline.merge(.move(dx: 1, dy: 1), .scroll(dx: 0, dy: 2, phase: nil)))
    }

    func testAnIdlePipelineAddsNoDelay() {
        let got = expectation(description: "delivered")
        let t0 = Date()
        let pipe = InputPipeline { _ in got.fulfill() }
        pipe.submit(.move(dx: 1, dy: 1))
        wait(for: [got], timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.25, "no timer sits in front of the first event")
    }
}

final class LaserSmootherTests: XCTestCase {
    func testGlidesTowardsTheTargetWithoutOvershoot() {
        var s = LaserSmoother(start: CGPoint(x: 0, y: 0), tau: 0.05)
        s.target = CGPoint(x: 1, y: 0.5)
        var last = 0.0
        for _ in 0..<30 {
            let p = s.step(dt: 1.0 / 60)
            XCTAssertGreaterThanOrEqual(p.x, last)
            XCTAssertLessThanOrEqual(p.x, 1)
            last = p.x
        }
        XCTAssertGreaterThan(last, 0.95)
        for _ in 0..<120 { s.step(dt: 1.0 / 60) }
        XCTAssertTrue(s.isSettled)
    }

    func testTheSameResultAtAnyFrameRate() {
        var a = LaserSmoother(start: .zero), b = LaserSmoother(start: .zero)
        a.target = CGPoint(x: 1, y: 1); b.target = CGPoint(x: 1, y: 1)
        for _ in 0..<10 { a.step(dt: 0.01) }
        b.step(dt: 0.1)
        XCTAssertEqual(a.current.x, b.current.x, accuracy: 1e-9)
    }

    func testJumpAndMailbox() {
        var s = LaserSmoother()
        s.jump(to: CGPoint(x: 0.2, y: 0.9))
        XCTAssertEqual(s.current, CGPoint(x: 0.2, y: 0.9))
        let m = LaserMailbox()
        let v0 = m.get().version
        m.set(x: 0.1, y: 0.2)
        let r = m.get()
        XCTAssertEqual(r.point, CGPoint(x: 0.1, y: 0.2))
        XCTAssertEqual(r.version, v0 + 1)
    }
}

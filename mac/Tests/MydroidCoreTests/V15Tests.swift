import XCTest
import CoreGraphics
import Network
@testable import MydroidCore

final class FakeAccessibility: AccessibilityChecking {
    var isTrusted: Bool
    init(_ t: Bool) { isTrusted = t }
}

final class FakeRunner: CommandRunning, @unchecked Sendable {
    struct Call: Equatable { let path: String; let args: [String] }
    var calls: [Call] = []
    var result = CommandResult()
    func run(_ path: String, _ arguments: [String], answerAfter: TimeInterval, killOnTimeout: Bool,
             completion: @escaping @Sendable (CommandResult) -> Void) {
        calls.append(Call(path: path, args: arguments))
        completion(result)
    }
}

final class FakeRing: RingControlling {
    var starts = 0, stops = 0
    func startRinging() { starts += 1 }
    func stopRinging() { stops += 1 }
}

final class TransportTests: XCTestCase {
    func testSessionConnectionsSetTcpNoDelay() throws {
        let params = Server.listenerParameters()
        let tcp = try XCTUnwrap(params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)
        XCTAssertTrue(tcp.noDelay, "PROTOCOL.md 10: both sides MUST set TCP_NODELAY")
        XCTAssertTrue(params.allowLocalEndpointReuse)
    }
}

final class MacActionServiceTests: XCTestCase {
    let poster = RecordingPoster()
    let runner = FakeRunner()
    let ring = FakeRing()

    func service(trusted: Bool) -> MacActionService {
        MacActionService(accessibility: FakeAccessibility(trusted), poster: poster, runner: runner, ring: ring)
    }

    func perform(_ s: MacActionService, _ a: MacAction) -> MacActionResult {
        var out: MacActionResult?
        s.perform(a) { out = $0 }
        return out!
    }

    func testLockPostsControlCommandQWhenAllowed() {
        let r = perform(service(trusted: true), .lock)
        XCTAssertEqual(r, .success)
        XCTAssertEqual(poster.events, [.key(code: 12, down: true, flags: [.control, .command]), .key(code: 12, down: false, flags: [.control, .command])])
        XCTAssertTrue(runner.calls.isEmpty, "no pmset when the chord can be posted")
    }

    func testLockFallsBackToDisplaySleepWithoutAccessibilityAndSaysSo() {
        let r = perform(service(trusted: false), .lock)
        XCTAssertTrue(poster.events.isEmpty, "nothing posted without permission")
        XCTAssertEqual(runner.calls, [.init(path: "/usr/bin/pmset", args: ["displaysleepnow"])])
        XCTAssertEqual(r, MacActionResult(ok: true, error: nil, note: "displaysleep"))
    }

    func testSleepAndDisplaySleepUsePmset() {
        let s = service(trusted: true)
        XCTAssertEqual(perform(s, .sleep), .success)
        XCTAssertEqual(perform(s, .displaySleep), .success)
        XCTAssertEqual(runner.calls.map(\.args), [["sleepnow"], ["displaysleepnow"]])
        XCTAssertTrue(runner.calls.allSatisfy { $0.path == "/usr/bin/pmset" })
    }

    func testPmsetFailureIsReported() {
        runner.result = CommandResult(status: 1, error: "nope")
        XCTAssertEqual(perform(service(trusted: true), .sleep).ok, false)
        runner.result = CommandResult(status: -1, launchFailed: true)
        XCTAssertEqual(perform(service(trusted: true), .displaySleep).ok, false)
    }

    func testRingStartsAndStops() {
        let s = service(trusted: false)
        XCTAssertEqual(perform(s, .ring), .success)
        XCTAssertEqual(perform(s, .ringStop), .success)
        XCTAssertEqual(ring.starts, 1); XCTAssertEqual(ring.stops, 1)
    }

    func testShortcutRunsByNameAsOneArgument() {
        let s = service(trusted: false)
        XCTAssertEqual(perform(s, .shortcut("Good Night; rm -rf ~")), .success)
        XCTAssertEqual(runner.calls, [.init(path: "/usr/bin/shortcuts", args: ["run", "Good Night; rm -rf ~"])], "one argv entry, never a shell")
    }

    func testShortcutFailureAndRunningLong() {
        runner.result = CommandResult(status: 1, error: "Couldn't find shortcut")
        let bad = perform(service(trusted: false), .shortcut("Nope"))
        XCTAssertFalse(bad.ok)
        XCTAssertNotNil(bad.error)
        runner.result = CommandResult(status: 0, stillRunning: true)
        XCTAssertEqual(perform(service(trusted: false), .shortcut("Slow")), .success, "still running after the grace period counts as started")
    }

    func testShortcutNameValidation() {
        XCTAssertTrue(MacActionService.validShortcutName("Good Night"))
        XCTAssertTrue(MacActionService.validShortcutName("\u{1F319} Sleep"))
        for bad in ["", "   ", "-v", "a\nb", "a\u{0}b", String(repeating: "x", count: 201)] {
            XCTAssertFalse(MacActionService.validShortcutName(bad), bad)
        }
        let r = perform(service(trusted: false), .shortcut("-h"))
        XCTAssertFalse(r.ok)
        XCTAssertTrue(runner.calls.isEmpty, "an invalid name never reaches the command")
    }

    func testListShortcuts() {
        runner.result = CommandResult(output: "Good Night\nWork Focus\n\n  Good Night  \nPlay Music\n")
        var got: Result<[String], MacActionFailure>?
        service(trusted: false).listShortcuts { got = $0 }
        XCTAssertEqual(try got?.get(), ["Good Night", "Work Focus", "Play Music"])
        XCTAssertEqual(runner.calls, [.init(path: "/usr/bin/shortcuts", args: ["list"])])
        runner.result = CommandResult(status: 1)
        service(trusted: false).listShortcuts { got = $0 }
        XCTAssertThrowsError(try got?.get())
        XCTAssertEqual(MacActionService.parseShortcuts(String(repeating: "a\nb\n", count: 10)), ["a", "b"])
        XCTAssertEqual(MacActionService.parseShortcuts((0..<900).map(String.init).joined(separator: "\n")).count, 500)
    }

    func testActionParsing() {
        func a(_ f: [String: Any]) -> MacAction? { MacAction(message: Message("mac.action", f)) }
        XCTAssertEqual(a(["action": "lock"]), .lock)
        XCTAssertEqual(a(["action": "sleep"]), .sleep)
        XCTAssertEqual(a(["action": "displaysleep"]), .displaySleep)
        XCTAssertEqual(a(["action": "ring"]), .ring)
        XCTAssertEqual(a(["action": "ringstop"]), .ringStop)
        XCTAssertEqual(a(["action": "shortcut", "name": "X"]), .shortcut("X"))
        XCTAssertNil(a(["action": "shortcut"]))
        XCTAssertNil(a(["action": "reboot"]))
    }

    func testStatusAndRemoteWire() {
        let s = MacStatus(name: "Mac", model: "MacBookPro18,3", battery: 80, charging: true, locked: false, displayAsleep: true)
        XCTAssertEqual(s.wireFields["battery"] as? Int, 80)
        XCTAssertEqual(s.wireFields["displayAsleep"] as? Bool, true)
        XCTAssertTrue(MacStatus(name: "Mini").wireFields["battery"] is NSNull, "null on a desktop")
        XCTAssertTrue(RemoteStatus(accessibility: true).wireFields["presenting"] is NSNull)
        XCTAssertEqual((RemoteStatus(accessibility: true, presenting: "Keynote").wireFields["presenting"] as? [String: String])?["app"], "Keynote")
    }

    func testSettingsCarryWalkAway() throws {
        var s = SyncSettings()
        XCTAssertEqual(s.wireFields["walkAway"] as? Bool, false, "off by default")
        s.walkAway = true
        XCTAssertEqual(s.wireFields["walkAway"] as? Bool, true)
        let round = try JSONDecoder().decode(SyncSettings.self, from: try JSONEncoder().encode(s))
        XCTAssertEqual(round, s)
        let old = try JSONDecoder().decode(SyncSettings.self, from: Data(#"{"notifications":true,"photos":true,"calls":true,"clipboard":false}"#.utf8))
        XCTAssertFalse(old.walkAway, "settings saved by an older build")
    }
}

private final class Inputs: @unchecked Sendable {
    private let lock = NSLock(); private var items: [RemoteInput] = []
    func add(_ i: RemoteInput) { lock.lock(); items.append(i); lock.unlock() }
    var all: [RemoteInput] { lock.lock(); defer { lock.unlock() }; return items }
}
private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0; private var evs: [String] = []
    func tick() { lock.lock(); n += 1; lock.unlock() }
    func event(_ s: String) { lock.lock(); evs.append(s); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return evs }
}

final class V15LoopbackTests: XCTestCase {
    private func makeHub(_ dir: URL, ltk: Data) -> Hub {
        let store = FileKeyValueStore(directory: dir.appendingPathComponent("secrets"))
        let identity = Identity(store: store)
        identity.savePairing(phoneId: "phone-1", ltk: ltk, phoneName: "Pixel 9")
        return Hub(HubConfiguration(macName: "Test Mac", identity: identity, config: store,
                                    ledgerURL: dir.appendingPathComponent("ledger.json"),
                                    photosDirectory: dir.appendingPathComponent("Pictures"),
                                    downloadsDirectory: dir.appendingPathComponent("Downloads"),
                                    preferredPort: 0, advertiseBonjour: false))
    }

    func testRemoteQuickActionsAndStatusOverTheWire() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mydroid-v15-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ltk = MydroidCrypto.randomBytes(32)
        let hub = makeHub(dir, ltk: ltk)
        XCTAssertEqual(hub.snapshot.phoneBleUUID, MydroidCrypto.phoneBleUUID(ltk: ltk), "the walk-away UUID is known as soon as paired")

        let inputs = Inputs(), counter = Counter()
        hub.onRemoteInput = { inputs.add($0) }
        hub.onState = { _ in counter.tick() }
        hub.onEvent = { if case .remoteAsk = $0 { counter.event("ask") } }
        let runner = FakeRunner(); runner.result = CommandResult(output: "A\nB\n")
        let poster = RecordingPoster(), ring = FakeRing()
        hub.macActions = MacActionService(accessibility: FakeAccessibility(false), poster: poster, runner: runner, ring: ring)
        // What the app reported before the phone connected.
        hub.setRemoteState(accessibility: false, presenting: nil)
        hub.setMacStatus(MacStatus(name: "Test Mac", model: "Mac14,2", battery: 71, charging: false, locked: false, displayAsleep: false))
        let port = try XCTUnwrap(hub.startAndWait())
        defer { hub.stop() }

        let c = TestClient(port: port)
        try await c.connect()
        try await c.handshake(phoneId: "phone-1", macId: hub.macId, ltk: ltk, pairing: false)
        let settings = try await c.receive(type: "settings")
        XCTAssertEqual(settings.bool("walkAway"), false)

        // On connect: remote.state and mac.status.
        let rs = try await c.receive(type: "remote.state")
        XCTAssertEqual(rs.bool("accessibility"), false)
        XCTAssertTrue(rs.fields["presenting"] is NSNull)
        let ms = try await c.receive(type: "mac.status")
        XCTAssertEqual(ms.int("battery"), 71)
        XCTAssertEqual(ms.string("model"), "Mac14,2")
        XCTAssertEqual(ms.bool("locked"), false)
        XCTAssertEqual(ms.string("name"), "Test Mac")

        // A change goes out; the same thing again does not.
        hub.setRemoteState(accessibility: true, presenting: "Keynote")
        let rs2 = try await c.receive(type: "remote.state")
        XCTAssertEqual(rs2.bool("accessibility"), true)
        XCTAssertEqual((rs2.fields["presenting"] as? [String: Any])?["app"] as? String, "Keynote")
        hub.setRemoteState(accessibility: true, presenting: "Keynote")
        hub.setMacStatus(MacStatus(name: "Test Mac", model: "Mac14,2", battery: 71, charging: false, locked: false, displayAsleep: false))   // unchanged
        hub.setMacStatus(MacStatus(name: "Test Mac", model: "Mac14,2", battery: 71, charging: false, locked: true, displayAsleep: false))
        let ms2 = try await c.receive(type: "mac.status")
        XCTAssertEqual(ms2.bool("locked"), true, "the unchanged status was not sent, so the next one received is the real change")

        // Input is handed over without publishing state or emitting events.
        let before = counter.count
        for i in 0..<200 { try await c.send(Message("in.move", ["dx": Double(i), "dy": 0.5])) }
        try await c.send(Message("in.click", ["button": "left", "count": 2]))
        try await c.send(Message("in.key", ["key": "right", "mods": ["shift"]]))
        try await c.send(Message("in.key", ["key": "bogus"]))          // dropped
        try await c.send(Message("in.scroll", ["dx": 0, "dy": 3, "phase": "began"]))
        try await c.send(Message("in.laser", ["on": true, "x": 0.1, "y": 0.2]))
        try await c.send(Message("in.media", ["action": "playpause"]))
        try await c.send(Message("in.text", ["text": "hi"]))
        try await c.send(Message("ping")); _ = try await c.receive(type: "pong")
        let got = inputs.all
        XCTAssertEqual(got.count, 200 + 6, "every valid input arrived in order; the bad key was dropped")
        XCTAssertEqual(got.first, .move(dx: 0, dy: 0.5))
        XCTAssertEqual(got[199], .move(dx: 199, dy: 0.5))
        XCTAssertEqual(Array(got[200...]), [.click(.left, count: 2), .key("right", mods: [.shift]),
                                            .scroll(dx: 0, dy: 3, phase: .began), .laser(on: true, x: 0.1, y: 0.2), .media(.playPause), .text("hi")])
        XCTAssertEqual(counter.count - before, 1, "only the ping used to synchronise published; the 206 inputs did not (that would hop to the main thread at 120 Hz)")

        // remote.ask raises an event.
        try await c.send(Message("remote.ask"))
        try await c.send(Message("ping")); _ = try await c.receive(type: "pong")
        XCTAssertEqual(counter.events, ["ask"])

        // Quick actions: always answered, echoing req (number or string).
        try await c.send(Message("mac.action", ["req": 7, "action": "ring"]))
        let r1 = try await c.receive(type: "mac.result")
        XCTAssertEqual(r1.int("req"), 7); XCTAssertEqual(r1.bool("ok"), true)
        XCTAssertEqual(ring.starts, 1)
        try await c.send(Message("mac.action", ["req": "abc", "action": "ringstop"]))
        let r2 = try await c.receive(type: "mac.result")
        XCTAssertEqual(r2.string("req"), "abc"); XCTAssertEqual(r2.bool("ok"), true)
        try await c.send(Message("mac.action", ["req": 8, "action": "lock"]))
        let r3 = try await c.receive(type: "mac.result")
        XCTAssertEqual(r3.int("req"), 8); XCTAssertEqual(r3.bool("ok"), true)
        XCTAssertEqual(r3.string("note"), "displaysleep", "no Accessibility: fell back, and says so")
        XCTAssertEqual(runner.calls.last?.args, ["displaysleepnow"])
        try await c.send(Message("mac.action", ["req": 9, "action": "teleport"]))
        let r4 = try await c.receive(type: "mac.result")
        XCTAssertEqual(r4.int("req"), 9); XCTAssertEqual(r4.bool("ok"), false); XCTAssertNotNil(r4.string("error"))
        try await c.send(Message("mac.action", ["req": 10, "action": "shortcut", "name": "Good Night"]))
        let r5 = try await c.receive(type: "mac.result")
        XCTAssertEqual(r5.bool("ok"), true)
        XCTAssertEqual(runner.calls.last, .init(path: "/usr/bin/shortcuts", args: ["run", "Good Night"]))

        try await c.send(Message("mac.shortcuts.get", ["req": 11]))
        let sc = try await c.receive(type: "mac.shortcuts")
        XCTAssertEqual(sc.int("req"), 11)
        XCTAssertEqual(sc.fields["items"] as? [String], ["A", "B"])

        // Settings carry walkAway to the phone.
        var s = hub.snapshot.settings
        s.walkAway = true
        hub.setSettings(s)
        let s2 = try await c.receive(type: "settings")
        XCTAssertEqual(s2.bool("walkAway"), true)

        // Without a handler (the headless test server) every action still gets an answer.
        hub.macActions = nil
        try await c.send(Message("mac.action", ["req": 12, "action": "lock"]))
        let r6 = try await c.receive(type: "mac.result")
        XCTAssertEqual(r6.int("req"), 12); XCTAssertEqual(r6.bool("ok"), false); XCTAssertEqual(r6.string("error"), "unsupported")
        try await c.send(Message("mac.shortcuts.get", ["req": 13]))
        let sc2 = try await c.receive(type: "mac.shortcuts")
        XCTAssertEqual(sc2.string("error"), "unsupported")

        // A reconnect gets both states again.
        c.drop()
        let c2 = TestClient(port: port)
        try await c2.connect()
        try await c2.handshake(phoneId: "phone-1", macId: hub.macId, ltk: ltk, pairing: false)
        let again = try await c2.receive(type: "remote.state")
        XCTAssertEqual(again.bool("accessibility"), true)
        let ms3 = try await c2.receive(type: "mac.status")
        XCTAssertEqual(ms3.bool("locked"), true)
        c2.drop()
    }
}

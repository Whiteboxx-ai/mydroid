import XCTest
import CryptoKit
@testable import MydroidCore

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [HubEvent] = []
    private var cursor = 0
    func add(_ e: HubEvent) { lock.lock(); events.append(e); lock.unlock() }
    private func scan<T>(_ match: (HubEvent) -> T?) -> T? {
        lock.lock(); defer { lock.unlock() }
        while cursor < events.count {
            let e = events[cursor]; cursor += 1
            if let r = match(e) { return r }
        }
        return nil
    }
    func next<T>(timeout: TimeInterval = 5, _ match: (HubEvent) -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let r = scan(match) { return r }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "test", code: 3, userInfo: [NSLocalizedDescriptionKey: "timed out waiting for hub event"])
    }
}

final class LoopbackTests: XCTestCase {
    var dir: URL!
    var hub: Hub!
    fileprivate var events: EventLog!
    var port: UInt16 = 0
    var macId = ""

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mydroid-loop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = FileKeyValueStore(directory: dir.appendingPathComponent("secrets"))
        let cfg = HubConfiguration(
            macName: "Test Mac", identity: Identity(store: store), config: store,
            ledgerURL: dir.appendingPathComponent("ledger.json"),
            photosDirectory: dir.appendingPathComponent("Pictures"),
            downloadsDirectory: dir.appendingPathComponent("Downloads"),
            preferredPort: 0, advertiseBonjour: false)
        hub = Hub(cfg)
        events = EventLog()
        let ev = events!
        hub.onEvent = { ev.add($0) }
        macId = hub.macId
        port = try XCTUnwrap(hub.startAndWait())
    }

    override func tearDown() async throws {
        hub.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    private func randomFile(_ name: String, bytes: Int) throws -> URL {
        let u = dir.appendingPathComponent(name)
        try MydroidCrypto.randomBytes(bytes).write(to: u)
        return u
    }

    private func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    func testListenerRestartKeepsThePortKnownToThePhone() async throws {
        let previous = TestClient(port: port)
        try await previous.connect()
        defer { previous.drop() }

        hub.restartListener(dropConnections: true)
        let deadline = Date().addingTimeInterval(5)
        while hub.listeningPort == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(hub.listeningPort, port)

        let reconnect = TestClient(port: port)
        try await reconnect.connect()
        reconnect.drop()
    }

    /// Streams `data` as chunks from `offset`, up to `maxChunks`, and optionally sends `xfer.end`.
    private func stream(_ c: TestClient, xid: String, data: Data, from offset: Int, maxChunks: Int = .max, end: Bool) async throws {
        var off = offset, n = 0
        while off < data.count && n < maxChunks {
            let slice = data.subdata(in: off..<min(off + 262144, data.count))
            try await c.send(Message("xfer.chunk", ["xid": xid, "offset": off], payload: slice))
            off += slice.count; n += 1
        }
        if end { try await c.send(Message("xfer.end", ["xid": xid, "sha256": sha(data)])) }
    }

    func testPairReconnectTransferResumeAndDedupe() async throws {
        // --- Pairing ---------------------------------------------------------
        hub.startPairing()
        var urlString: String?
        for _ in 0..<200 { urlString = hub.pairURL; if urlString != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let comps = try XCTUnwrap(URLComponents(string: try XCTUnwrap(urlString)))
        func q(_ n: String) -> String? { comps.queryItems?.first { $0.name == n }?.value }
        XCTAssertEqual(comps.scheme, "mydroid")
        XCTAssertEqual(q("v"), "1")
        XCTAssertEqual(q("mac"), macId)
        XCTAssertEqual(q("n"), "Test Mac")
        XCTAssertTrue(q("a")?.contains(":\(port)") ?? false, "addresses carry the listening port")
        let secret = try XCTUnwrap(Data(base64url: try XCTUnwrap(q("s"))))
        XCTAssertEqual(secret.count, 32)
        let ltk = MydroidCrypto.ltk(fromPairingSecret: secret)
        let phoneId = UUID().uuidString.lowercased()

        let c1 = TestClient(port: port)
        try await c1.connect()
        try await c1.handshake(phoneId: phoneId, macId: macId, ltk: ltk, pairing: true)
        let (code, phoneName) = try await events.next { e -> (String, String)? in
            if case let .confirmCode(code, name) = e { return (code, name) } else { return nil }
        }
        XCTAssertEqual(code, c1.confirmCode, "both sides derive the same confirm code")
        XCTAssertEqual(phoneName, "Pixel 9")
        XCTAssertEqual(hub.snapshot.pairing?.confirmCode, code)
        hub.setSettings(.all)
        hub.confirmPairing()
        _ = try await c1.receive(type: "pair.confirmed")
        let settings = try await c1.receive(type: "settings")
        XCTAssertEqual(settings.bool("notifications"), true)
        XCTAssertEqual(settings.bool("clipboard"), true)
        XCTAssertNil(hub.pairURL, "QR is consumed by the pairing")
        try await c1.send(Message("bye"))
        c1.drop()
        _ = try await events.next { e -> Bool? in if case .sessionClosed = e { return true } else { return nil } }

        // A stranger with the right LTK but unknown phone id is refused.
        let stranger = TestClient(port: port)
        try await stranger.connect()
        do {
            try await stranger.handshake(phoneId: "not-the-phone", macId: macId, ltk: ltk, pairing: false)
            XCTFail("unknown phone must be rejected")
        } catch {}
        stranger.drop()

        // --- Reconnect -------------------------------------------------------
        let c2 = TestClient(port: port)
        try await c2.connect()
        try await c2.handshake(phoneId: phoneId, macId: macId, ltk: ltk, pairing: false)
        let s2 = try await c2.receive(type: "settings")
        XCTAssertEqual(s2.bool("photos"), true)
        try await c2.send(Message("device.status", ["battery": 78, "charging": false, "network": "wifi", "name": "Pixel 9", "model": "Pixel 9"]))
        try await c2.send(Message("feature.status", ["notifications": "on", "photos": "on", "calls": "on", "clipboard": "on", "backgroundRestricted": true]))
        try await c2.send(Message("notif.snapshot", ["items": [Any]()]))
        try await c2.send(Message("ping"))
        _ = try await c2.receive(type: "pong")
        var snap = hub.snapshot
        XCTAssertEqual(snap.link, .connected)
        XCTAssertEqual(snap.phone?.battery, 78)
        XCTAssertEqual(snap.phone?.network, .wifi)
        XCTAssertTrue(snap.fixes.isEmpty, "standard battery optimization does not restrict background activity")

        try await c2.send(Message("feature.status", ["notifications": "on", "photos": "on", "calls": "on", "clipboard": "on", "backgroundActivityRestricted": true]))
        try await c2.send(Message("ping"))
        _ = try await c2.receive(type: "pong")
        snap = hub.snapshot
        XCTAssertEqual(snap.fixes, [.background])

        try await c2.send(Message("feature.status", ["notifications": "on", "photos": "on", "calls": "on", "clipboard": "on", "backgroundActivityRestricted": false]))
        try await c2.send(Message("ping"))
        _ = try await c2.receive(type: "pong")
        XCTAssertTrue(hub.snapshot.fixes.isEmpty)

        // --- Notification + reply -------------------------------------------
        try await c2.send(Message("notif.posted", ["key": "k1", "pkg": "com.x", "app": "Messages", "title": "Maya Tan",
                                                  "text": "Are we still on for coffee?", "when": 1_700_000_000_000, "canReply": true, "actions": [Any]()]))
        let isNew = try await events.next { e -> Bool? in if case let .notificationPosted(n, new) = e, n.key == "k1" { return new } else { return nil } }
        XCTAssertTrue(isNew)
        XCTAssertEqual(hub.snapshot.notifications.items.first?.title, "Maya Tan")
        hub.reply(key: "k1", text: "On my way")
        let reply = try await c2.receive(type: "notif.reply")
        XCTAssertEqual(reply.string("key"), "k1")
        XCTAssertEqual(reply.string("text"), "On my way")
        try await c2.send(Message("notif.result", ["key": "k1", "ok": true]))
        try await c2.send(Message("notif.removed", ["key": "k1"]))
        _ = try await events.next { e -> Bool? in if case .notificationRemoved = e { return true } else { return nil } }
        XCTAssertTrue(hub.snapshot.notifications.items.isEmpty)

        // --- Photo transfer --------------------------------------------------
        let photo1 = try Data(contentsOf: try randomFile("p1.bin", bytes: 700_000))
        try await c2.send(Message("xfer.offer", ["xid": "photo:1:100", "kind": "photo", "name": "IMG_0001.jpg", "size": photo1.count, "mime": "image/jpeg", "taken": 1_700_000_000_000]))
        let acc = try await c2.receive(type: "xfer.accept")
        XCTAssertEqual(acc.int("offset"), 0)
        try await stream(c2, xid: "photo:1:100", data: photo1, from: 0, end: true)
        let done1 = try await c2.receive(type: "xfer.done")
        XCTAssertEqual(done1.bool("ok"), true)
        let saved1 = dir.appendingPathComponent("Pictures/IMG_0001.jpg")
        XCTAssertEqual(try Data(contentsOf: saved1), photo1)
        XCTAssertEqual(hub.snapshot.latestPhoto?.name, "IMG_0001.jpg")

        // --- Resume ----------------------------------------------------------
        let photo2 = try Data(contentsOf: try randomFile("p2.bin", bytes: 1_000_000))
        try await c2.send(Message("xfer.offer", ["xid": "photo:2:100", "kind": "photo", "name": "IMG_0002.jpg", "size": photo2.count, "mime": "image/jpeg"]))
        do { let m = try await c2.receive(type: "xfer.accept"); XCTAssertEqual(m.int("offset"), 0) }
        try await stream(c2, xid: "photo:2:100", data: photo2, from: 0, maxChunks: 1, end: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        c2.drop()   // no bye
        _ = try await events.next { e -> Bool? in if case .sessionClosed = e { return true } else { return nil } }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Incoming/IMG_0002.jpg.part").path), "partial waits in staging")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Pictures/IMG_0002.jpg.part").path), "nothing half-done in Pictures")

        let c3 = TestClient(port: port)
        try await c3.connect()
        try await c3.handshake(phoneId: phoneId, macId: macId, ltk: ltk, pairing: false)
        try await c3.send(Message("xfer.offer", ["xid": "photo:2:100", "kind": "photo", "name": "IMG_0002.jpg", "size": photo2.count, "mime": "image/jpeg"]))
        let resumed = try await c3.receive(type: "xfer.accept")
        XCTAssertEqual(resumed.int("offset"), 262144, "resume from the .part size")
        try await stream(c3, xid: "photo:2:100", data: photo2, from: 262144, end: true)
        do { let m = try await c3.receive(type: "xfer.done"); XCTAssertEqual(m.bool("ok"), true) }
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("Pictures/IMG_0002.jpg")), photo2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Incoming/IMG_0002.jpg.part").path))

        // --- Dedupe ----------------------------------------------------------
        try await c3.send(Message("xfer.offer", ["xid": "photo:1:100", "kind": "photo", "name": "IMG_0001.jpg", "size": photo1.count, "mime": "image/jpeg"]))
        do { let m = try await c3.receive(type: "xfer.skip"); XCTAssertEqual(m.string("xid"), "photo:1:100") }
        // Same name, different xid: saved with a unique name.
        try await c3.send(Message("xfer.offer", ["xid": "photo:9:100", "kind": "photo", "name": "IMG_0001.jpg", "size": photo1.count, "mime": "image/jpeg"]))
        do { let m = try await c3.receive(type: "xfer.accept"); XCTAssertEqual(m.int("offset"), 0) }
        try await stream(c3, xid: "photo:9:100", data: photo1, from: 0, end: true)
        do { let m = try await c3.receive(type: "xfer.done"); XCTAssertEqual(m.bool("ok"), true) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Pictures/IMG_0001 (2).jpg").path))
        // Bad checksum is refused and not recorded.
        try await c3.send(Message("xfer.offer", ["xid": "photo:10:1", "kind": "photo", "name": "bad.jpg", "size": 5, "mime": "image/jpeg"]))
        _ = try await c3.receive(type: "xfer.accept")
        try await c3.send(Message("xfer.chunk", ["xid": "photo:10:1", "offset": 0], payload: Data([1, 2, 3, 4, 5])))
        try await c3.send(Message("xfer.end", ["xid": "photo:10:1", "sha256": String(repeating: "0", count: 64)]))
        do { let m = try await c3.receive(type: "xfer.done"); XCTAssertEqual(m.bool("ok"), false) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Pictures/bad.jpg").path))

        // The ledger survives a restart of the Hub's ledger object.
        XCTAssertTrue(TransferLedger(url: dir.appendingPathComponent("ledger.json")).has("photo:1:100"))

        // --- Mac -> phone file ----------------------------------------------
        let hello = dir.appendingPathComponent("hello.txt")
        try Data("hello from mac\n".utf8).write(to: hello)
        XCTAssertTrue(hub.sendFile(hello))
        let offer = try await c3.receive(type: "xfer.offer")
        XCTAssertEqual(offer.string("name"), "hello.txt")
        XCTAssertEqual(offer.string("kind"), "file")
        XCTAssertTrue(offer.string("xid")!.hasPrefix("file:"))
        try await c3.send(Message("xfer.accept", ["xid": offer.string("xid")!, "offset": 0]))
        let chunk = try await c3.receive(type: "xfer.chunk")
        XCTAssertEqual(chunk.payload, Data("hello from mac\n".utf8))
        let end = try await c3.receive(type: "xfer.end")
        XCTAssertEqual(end.string("sha256"), sha(Data("hello from mac\n".utf8)))
        try await c3.send(Message("xfer.done", ["xid": offer.string("xid")!, "ok": true]))
        let sent = try await events.next { e -> Bool? in if case let .sent(_, name, skipped) = e { return name == "hello.txt" && !skipped } else { return nil } }
        XCTAssertTrue(sent)

        // --- Clipboard --------------------------------------------------------
        try await c3.send(Message("clip.set", ["text": "hello from phone"]))
        let clip = try await events.next { e -> String? in if case let .clipboard(t) = e { return t } else { return nil } }
        XCTAssertEqual(clip, "hello from phone")
        hub.sendClipboard("hello from mac")
        do { let m = try await c3.receive(type: "clip.set"); XCTAssertEqual(m.string("text"), "hello from mac") }

        // --- Calls, fix, find -------------------------------------------------
        try await c3.send(Message("call.state", ["callId": "c1", "state": "ringing", "incoming": true, "name": "Maya Tan", "number": "+1555"]))
        for _ in 0..<100 where hub.snapshot.call == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        snap = hub.snapshot
        XCTAssertEqual(snap.call?.displayName, "Maya Tan")
        hub.callAction("answer")
        let ca = try await c3.receive(type: "call.action")
        XCTAssertEqual(ca.string("action"), "answer")
        XCTAssertEqual(ca.string("callId"), "c1")
        hub.fix(.background)
        do { let m = try await c3.receive(type: "fix.open"); XCTAssertEqual(m.string("what"), "background") }
        hub.findPhone()
        _ = try await c3.receive(type: "find.ring")

        // --- Unpair -----------------------------------------------------------
        hub.unpair()
        _ = try await c3.receive(type: "unpair")
        XCTAssertFalse(hub.snapshot.link == .connected)
        c3.drop()
    }

    func testPairRejectedSendsPairRejected() async throws {
        hub.startPairing()
        var url: String?
        for _ in 0..<200 { url = hub.pairURL; if url != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let comps = URLComponents(string: url!)!
        let s = Data(base64url: comps.queryItems!.first { $0.name == "s" }!.value!)!
        let c = TestClient(port: port)
        try await c.connect()
        try await c.handshake(phoneId: "p", macId: macId, ltk: MydroidCrypto.ltk(fromPairingSecret: s), pairing: true)
        _ = try await events.next { e -> Bool? in if case .confirmCode = e { return true } else { return nil } }
        hub.rejectPairing()
        _ = try await c.receive(type: "pair.rejected")
        XCTAssertNotEqual(hub.pairURL, url, "a fresh QR replaces the rejected one")
    }
}

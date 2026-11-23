import XCTest
import CryptoKit
@testable import MydroidCore

/// Runs the real `mydroid-test-server` binary against an in-process Swift "phone simulator" that
/// follows PROTOCOL.md section 6. Proves the driver's 10 steps (including resume and dedupe) end to end.
final class SmokeDriverTests: XCTestCase {
    final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func append(_ s: String) { lock.lock(); text += s; lock.unlock() }
        var value: String { lock.lock(); defer { lock.unlock() }; return text }
    }

    private func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    func testServerDriverAgainstSimulator() async throws {
        // Locate the built executable next to the test bundle.
        let products = Bundle(for: SmokeDriverTests.self).bundleURL.deletingLastPathComponent()
        let exe = products.appendingPathComponent("mydroid-test-server")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: exe.path), "mydroid-test-server not built at \(exe.path)")

        let data = FileManager.default.temporaryDirectory.appendingPathComponent("mydroid-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: data) }
        let proc = Process()
        proc.executableURL = exe
        proc.arguments = ["--data", data.path, "--port", "0"]
        let pipe = Pipe()
        let out = Output()
        proc.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            if let s = String(data: h.availableData, encoding: .utf8) { out.append(s) }
        }
        try proc.run()
        defer { if proc.isRunning { proc.terminate() } }

        var urlLine: String?
        for _ in 0..<300 {
            urlLine = out.value.split(separator: "\n").first { $0.hasPrefix("PAIR_URL ") }.map(String.init)
            if urlLine != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let url = URLComponents(string: String(try XCTUnwrap(urlLine).dropFirst("PAIR_URL ".count)))!
        func q(_ n: String) -> String { url.queryItems!.first { $0.name == n }!.value! }
        let macId = q("mac")
        let port = UInt16(q("a").split(separator: ",")[0].split(separator: ":")[1])!
        let ltk = MydroidCrypto.ltk(fromPairingSecret: Data(base64url: q("s"))!)
        let phoneId = UUID().uuidString.lowercased()

        func connect(pairing: Bool) async throws -> TestClient {
            let c = TestClient(port: port)
            try await c.connect()
            try await c.handshake(phoneId: phoneId, macId: macId, ltk: ltk, pairing: pairing)
            return c
        }
        func streamAll(_ c: TestClient, xid: String, _ d: Data, from: Int = 0, maxChunks: Int = .max, end: Bool = true) async throws {
            var off = from, n = 0
            while off < d.count && n < maxChunks {
                let s = d.subdata(in: off..<min(off + 262144, d.count))
                try await c.send(Message("xfer.chunk", ["xid": xid, "offset": off], payload: s)); off += s.count; n += 1
            }
            if end { try await c.send(Message("xfer.end", ["xid": xid, "sha256": sha(d)])) }
        }

        // 2. pair
        var c = try await connect(pairing: true)
        _ = try await c.receive(type: "pair.confirmed")
        XCTAssertTrue(out.value.contains("CONFIRM \(c.confirmCode)"))
        try await c.send(Message("bye")); c.drop()
        // 3. reconnect
        c = try await connect(pairing: false)
        let settings = try await c.receive(type: "settings")
        for k in ["notifications", "photos", "calls", "clipboard"] { XCTAssertEqual(settings.bool(k), true) }
        try await c.send(Message("device.status", ["battery": 78, "charging": false, "network": "wifi", "name": "Pixel 9", "model": "Pixel 9"]))
        try await c.send(Message("feature.status", ["notifications": "on", "photos": "on", "calls": "on", "clipboard": "on", "backgroundRestricted": false]))
        try await c.send(Message("notif.snapshot", ["items": [Any]()]))
        // 4. notification reply
        try await c.send(Message("notif.posted", ["key": "k1", "pkg": "p", "app": "Messages", "title": "Maya Tan", "text": "Are we still on for coffee?", "when": 1, "canReply": true, "actions": [Any]()]))
        let reply = try await c.receive(type: "notif.reply")
        XCTAssertEqual(reply.string("text"), "On my way")
        try await c.send(Message("notif.result", ["key": "k1", "ok": true]))
        try await c.send(Message("notif.removed", ["key": "k1"]))
        // 5. photo
        let p1 = MydroidCrypto.randomBytes(1_500_000), p2 = MydroidCrypto.randomBytes(1_500_000)
        try await c.send(Message("xfer.offer", ["xid": "photo:1:100", "kind": "photo", "name": "a.jpg", "size": p1.count, "mime": "image/jpeg"]))
        _ = try await c.receive(type: "xfer.accept")
        try await streamAll(c, xid: "photo:1:100", p1)
        let d1 = try await c.receive(type: "xfer.done"); XCTAssertEqual(d1.bool("ok"), true)
        // 6. resume
        try await c.send(Message("xfer.offer", ["xid": "photo:2:100", "kind": "photo", "name": "b.jpg", "size": p2.count, "mime": "image/jpeg"]))
        _ = try await c.receive(type: "xfer.accept")
        try await streamAll(c, xid: "photo:2:100", p2, maxChunks: 1, end: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        c.drop()
        try await Task.sleep(nanoseconds: 200_000_000)
        c = try await connect(pairing: false)
        try await c.send(Message("xfer.offer", ["xid": "photo:2:100", "kind": "photo", "name": "b.jpg", "size": p2.count, "mime": "image/jpeg"]))
        let acc = try await c.receive(type: "xfer.accept")
        XCTAssertEqual(acc.int("offset"), 262144)
        try await streamAll(c, xid: "photo:2:100", p2, from: 262144)
        let d2 = try await c.receive(type: "xfer.done"); XCTAssertEqual(d2.bool("ok"), true)
        // 7. dedupe
        try await c.send(Message("xfer.offer", ["xid": "photo:1:100", "kind": "photo", "name": "a.jpg", "size": p1.count, "mime": "image/jpeg"]))
        _ = try await c.receive(type: "xfer.skip")
        // 8. file from Mac
        let offer = try await c.receive(type: "xfer.offer")
        XCTAssertEqual(offer.string("name"), "hello.txt")
        let xid = offer.string("xid")!
        try await c.send(Message("xfer.accept", ["xid": xid, "offset": 0]))
        let chunk = try await c.receive(type: "xfer.chunk")
        let end = try await c.receive(type: "xfer.end")
        XCTAssertEqual(chunk.payload, Data("hello from mac\n".utf8))
        XCTAssertEqual(end.string("sha256"), sha(chunk.payload))
        try await c.send(Message("xfer.done", ["xid": xid, "ok": true]))
        // 9. clipboard
        try await c.send(Message("clip.set", ["text": "hello from phone"]))
        let clip = try await c.receive(type: "clip.set")
        XCTAssertEqual(clip.string("text"), "hello from mac")
        // 10. ping
        _ = try await c.receive(type: "ping")
        try await c.send(Message("pong"))
        try await c.send(Message("bye"))

        for _ in 0..<200 where proc.isRunning { try await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertFalse(proc.isRunning)
        XCTAssertEqual(proc.terminationStatus, 0, out.value)
        XCTAssertTrue(out.value.contains("SMOKE OK"), out.value)
        for n in 1...10 { XCTAssertTrue(out.value.contains("STEP \(n) ok"), "missing STEP \(n): \(out.value)") }
        pipe.fileHandleForReading.readabilityHandler = nil
    }
}

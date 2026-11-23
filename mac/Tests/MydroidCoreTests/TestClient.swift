import Foundation
import Network
import XCTest
@testable import MydroidCore

/// Minimal phone-side client for the loopback tests.
final class TestClient {
    let conn: NWConnection
    private let queue = DispatchQueue(label: "test.client")
    private var buffer = FrameBuffer()
    var sendCipher: FrameCipher?
    var recvCipher: FrameCipher?
    var confirmCode = ""

    init(port: UInt16) {
        conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            var done = false
            conn.stateUpdateHandler = { s in
                guard !done else { return }
                switch s {
                case .ready: done = true; c.resume()
                case .failed(let e): done = true; c.resume(throwing: e)
                default: break
                }
            }
            conn.start(queue: queue)
        }
    }

    func readRawFrame() async throws -> Data {
        while true {
            if let f = try buffer.next() { return f }
            let chunk: Data = try await withCheckedThrowingContinuation { c in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { d, _, complete, err in
                    if let err { c.resume(throwing: err) }
                    else if let d, !d.isEmpty { c.resume(returning: d) }
                    else if complete { c.resume(throwing: NSError(domain: "closed", code: 1)) }
                    else { c.resume(returning: Data()) }
                }
            }
            buffer.append(chunk)
        }
    }

    func sendRaw(_ d: Data) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            conn.send(content: d, completion: .contentProcessed { _ in c.resume() })
        }
    }

    /// Performs hello/hello/auth and reads `welcome`.
    func handshake(phoneId: String, macId: String, ltk: Data, pairing: Bool, name: String = "Pixel 9") async throws {
        let nonceC = MydroidCrypto.randomBytes(16)
        let hello: [String: Any] = ["t": "hello", "v": 1, "phone": phoneId, "mac": macId,
                                    "nonce": nonceC.base64EncodedString(), "pairing": pairing]
        await sendRaw(Framing.wrap(try JSONSerialization.data(withJSONObject: hello)))
        let reply = try JSONSerialization.jsonObject(with: try await readRawFrame()) as! [String: Any]
        XCTAssertEqual(reply["t"] as? String, "hello")
        XCTAssertEqual(reply["mac"] as? String, macId)
        let nonceS = Data(base64Encoded: reply["nonce"] as! String)!
        let keys = MydroidCrypto.sessionKeys(ltk: ltk, nonceC: nonceC, nonceS: nonceS)
        confirmCode = MydroidCrypto.confirmCode(ltk: ltk, nonceC: nonceC, nonceS: nonceS)
        sendCipher = FrameCipher(key: keys.c2s)
        recvCipher = FrameCipher(key: keys.s2c)
        try await send(Message("auth", ["name": name, "model": name, "android": 35]))
        let welcome = try await receive()
        XCTAssertEqual(welcome.type, "welcome")
    }

    func send(_ m: Message) async throws {
        let body = try sendCipher!.seal(try m.encode())
        await sendRaw(Framing.wrap(body))
    }

    func receive(timeout: TimeInterval = 5) async throws -> Message {
        try await withThrowingTaskGroup(of: Message.self) { group in
            group.addTask {
                let f = try await self.readRawFrame()
                return try Message.decode(try self.recvCipher!.open(f))
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                throw NSError(domain: "timeout", code: 2, userInfo: [NSLocalizedDescriptionKey: "client receive timeout"])
            }
            let m = try await group.next()!
            group.cancelAll()
            return m
        }
    }

    /// Reads messages until one of `type` arrives (skipping others such as settings).
    func receive(type: String) async throws -> Message {
        while true {
            let m = try await receive()
            if m.type == type { return m }
        }
    }

    func drop() { conn.cancel() }
}

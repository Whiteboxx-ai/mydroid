import XCTest
@testable import MydroidCore

final class VectorTests: XCTestCase {
    struct Frame: Decodable { let counter: UInt64; let dir: String; let frame: String; let plaintext: String }
    struct Vectors: Decodable {
        let c2sKey, s2cKey, confirmBytes, confirmCode, ltk, nonceClient, nonceServer, pairingSecret, pairingSecretB64url: String
        let frames: [Frame]
        let bleUuid: String
        let bleUuidRaw: String
        let phoneBleUuid: String
        let phoneBleUuidRaw: String
    }

    static func loadVectors() throws -> Vectors {
        // mac/Tests/MydroidCoreTests/VectorTests.swift -> repo root
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        let data = try Data(contentsOf: url.appendingPathComponent("protocol/test-vectors.json"))
        return try JSONDecoder().decode(Vectors.self, from: data)
    }

    func testKeyDerivation() throws {
        let v = try Self.loadVectors()
        let secret = Data(hex: v.pairingSecret)!
        XCTAssertEqual(secret.base64url, v.pairingSecretB64url)
        XCTAssertEqual(Data(base64url: v.pairingSecretB64url), secret)

        let ltk = MydroidCrypto.ltk(fromPairingSecret: secret)
        XCTAssertEqual(ltk.hex, v.ltk)

        let nc = Data(hex: v.nonceClient)!, ns = Data(hex: v.nonceServer)!
        let keys = MydroidCrypto.sessionKeys(ltk: ltk, nonceC: nc, nonceS: ns)
        XCTAssertEqual(keys.c2s.hex, v.c2sKey)
        XCTAssertEqual(keys.s2c.hex, v.s2cKey)

        let confirmBytes = MydroidCrypto.hkdf(ikm: ltk, salt: nc + ns, info: "mydroid v1 confirm", length: 4)
        XCTAssertEqual(confirmBytes.hex, v.confirmBytes)
        let code = MydroidCrypto.confirmCode(ltk: ltk, nonceC: nc, nonceS: ns)
        XCTAssertEqual(code, v.confirmCode)
        XCTAssertEqual(MydroidCrypto.displayCode(code), "181 734")
    }

    func testBleUuid() throws {
        let v = try Self.loadVectors()
        let ltk = Data(hex: v.ltk)!
        let raw = MydroidCrypto.hkdf(ikm: ltk, salt: Data(), info: "mydroid v1 ble uuid", length: 16)
        XCTAssertEqual(raw.hex, v.bleUuidRaw)
        XCTAssertEqual(MydroidCrypto.bleUUID(ltk: ltk), v.bleUuid)
        XCTAssertNotNil(UUID(uuidString: v.bleUuid))
    }

    func testPhoneBleUuid() throws {
        let v = try Self.loadVectors()
        let ltk = Data(hex: v.ltk)!
        let raw = MydroidCrypto.hkdf(ikm: ltk, salt: Data(), info: "mydroid v1 phone ble uuid", length: 16)
        XCTAssertEqual(raw.hex, v.phoneBleUuidRaw)
        XCTAssertEqual(MydroidCrypto.phoneBleUUID(ltk: ltk), v.phoneBleUuid)
        XCTAssertNotNil(UUID(uuidString: v.phoneBleUuid))
        XCTAssertNotEqual(v.phoneBleUuid, v.bleUuid, "walk-away uses its own UUID, so the Mac's own advert is never mistaken for the phone")
    }

    func testEncryptedFrames() throws {
        let v = try Self.loadVectors()
        XCTAssertEqual(v.frames.count, 3)
        for f in v.frames {
            let key = Data(hex: f.dir == "c2s" ? v.c2sKey : v.s2cKey)!
            let plaintext = Data(hex: f.plaintext)!
            let frame = Data(hex: f.frame)!
            var enc = FrameCipher(key: key, counter: f.counter)
            XCTAssertEqual(try enc.seal(plaintext).hex, f.frame, "seal \(f.dir)#\(f.counter)")
            var dec = FrameCipher(key: key, counter: f.counter)
            XCTAssertEqual(try dec.open(frame), plaintext, "open \(f.dir)#\(f.counter)")
            XCTAssertEqual(dec.counter, f.counter + 1)
            // Wrong counter and tampering are rejected.
            var wrong = FrameCipher(key: key, counter: f.counter + 1)
            XCTAssertThrowsError(try wrong.open(frame))
            var bad = frame; bad[bad.count - 1] ^= 1
            var dec2 = FrameCipher(key: key, counter: f.counter)
            XCTAssertThrowsError(try dec2.open(bad))
        }
    }

    func testVectorPlaintextsDecode() throws {
        let v = try Self.loadVectors()
        let auth = try Message.decode(Data(hex: v.frames[0].plaintext)!)
        XCTAssertEqual(auth.type, "auth")
        XCTAssertEqual(auth.string("name"), "Pixel 9")
        let chunk = try Message.decode(Data(hex: v.frames[1].plaintext)!)
        XCTAssertEqual(chunk.type, "xfer.chunk")
        XCTAssertEqual(chunk.string("xid"), "photo:1:100")
        XCTAssertEqual(chunk.int("offset"), 0)
        XCTAssertEqual(chunk.payload, Data([1, 2, 3, 4, 5]))
        let welcome = try Message.decode(Data(hex: v.frames[2].plaintext)!)
        XCTAssertEqual(welcome.type, "welcome")
        XCTAssertEqual(welcome.string("name"), "MacBook")
    }
}

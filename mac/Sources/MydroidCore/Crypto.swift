import Foundation
import CryptoKit

/// Key derivation and the encrypted frame cipher (PROTOCOL.md sections 3 and 4.2).
public enum MydroidCrypto {
    public static func hkdf(ikm: Data, salt: Data, info: String, length: Int) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: Data(info.utf8),
            outputByteCount: length)
        return key.withUnsafeBytes { Data($0) }
    }

    public static func ltk(fromPairingSecret s: Data) -> Data {
        hkdf(ikm: s, salt: Data(), info: "mydroid v1 ltk", length: 32)
    }

    public struct SessionKeys: Sendable {
        public let c2s: Data
        public let s2c: Data
    }

    public static func sessionKeys(ltk: Data, nonceC: Data, nonceS: Data) -> SessionKeys {
        let okm = hkdf(ikm: ltk, salt: nonceC + nonceS, info: "mydroid v1 session", length: 64)
        return SessionKeys(c2s: okm.prefix(32), s2c: okm.suffix(32))
    }

    /// BLE presence service UUID for a pairing (PROTOCOL.md 7.1), lowercase, e.g. "de7db8f7-4754-4ef1-ba50-10b977af2e8d".
    public static func bleUUID(ltk: Data) -> String { uuid(ltk: ltk, info: "mydroid v1 ble uuid") }

    /// The service UUID the phone advertises for walk-away lock (PROTOCOL.md 12), lowercase. Same derivation, different info string.
    public static func phoneBleUUID(ltk: Data) -> String { uuid(ltk: ltk, info: "mydroid v1 phone ble uuid") }

    static func uuid(ltk: Data, info: String) -> String {
        var raw = [UInt8](hkdf(ikm: ltk, salt: Data(), info: info, length: 16))
        raw[6] = (raw[6] & 0x0f) | 0x40
        raw[8] = (raw[8] & 0x3f) | 0x80
        let h = raw.map { String(format: "%02x", $0) }.joined()
        let a = Array(h)
        func part(_ r: Range<Int>) -> String { String(a[r]) }
        return [part(0..<8), part(8..<12), part(12..<16), part(16..<20), part(20..<32)].joined(separator: "-")
    }

    /// Six digits, e.g. "181734".
    public static func confirmCode(ltk: Data, nonceC: Data, nonceS: Data) -> String {
        let bytes = hkdf(ikm: ltk, salt: nonceC + nonceS, info: "mydroid v1 confirm", length: 4)
        let n = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return String(format: "%06u", n % 1_000_000)
    }

    /// "181734" -> "181 734"
    public static func displayCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return code.prefix(3) + " " + code.suffix(3)
    }

    public static func randomBytes(_ n: Int) -> Data {
        var d = Data(count: n)
        let status = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return d
    }
}

public enum CipherError: Error, Equatable {
    case shortFrame
    case counterMismatch
    case authenticationFailed
}

/// One direction of the encrypted channel. Nonce = 4 zero bytes || u64 BE counter.
public struct FrameCipher: Sendable {
    private let key: SymmetricKey
    public private(set) var counter: UInt64

    public init(key: Data, counter: UInt64 = 0) {
        self.key = SymmetricKey(data: key)
        self.counter = counter
    }

    static func nonceBytes(_ counter: UInt64) -> Data {
        var d = Data(repeating: 0, count: 4)
        for shift in stride(from: 56, through: 0, by: -8) { d.append(UInt8((counter >> UInt64(shift)) & 0xff)) }
        return d
    }

    /// Returns `nonce || ciphertext || tag`.
    public mutating func seal(_ plaintext: Data) throws -> Data {
        let nonceData = Self.nonceBytes(counter)
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: nonceData))
        counter += 1
        return nonceData + box.ciphertext + box.tag
    }

    public mutating func open(_ body: Data) throws -> Data {
        guard body.count >= 28 else { throw CipherError.shortFrame }
        let body = Data(body)
        let nonceData = body.prefix(12)
        guard nonceData == Self.nonceBytes(counter) else { throw CipherError.counterMismatch }
        let tag = body.suffix(16)
        let ct = body.dropFirst(12).dropLast(16)
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceData), ciphertext: ct, tag: tag)
            let pt = try AES.GCM.open(box, using: key)
            counter += 1
            return pt
        } catch {
            throw CipherError.authenticationFailed
        }
    }
}

public extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        self = out
    }

    var base64url: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64url: String) {
        var s = base64url.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
}

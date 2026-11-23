import Foundation
import CryptoKit
import CommonCrypto

// UKEY2 key agreement and the SecureMessage layer used by Quick Share, written from the description in NearDrop's PROTOCOL.md
// and its Swift implementation (Unlicense, public domain): https://github.com/grishka/NearDrop
// UKEY2 itself: https://github.com/google/ukey2

enum QSCryptoError: Error, Equatable {
    case badPublicKey
    case badSignature
    case badSequence(expected: Int32, got: Int32)
    case badMessage(String)
    case cipherFailure(Int32)
}

enum QSCrypto {
    /// SHA256("D2D"), the salt for the two device-to-device keys.
    static let d2dSalt = Data([0x82, 0xAA, 0x55, 0xA0, 0xD3, 0x97, 0xF8, 0x83, 0x46, 0xCA, 0x1C, 0xEE, 0x8D, 0x39, 0x09, 0xB9,
                               0x5F, 0x13, 0xFA, 0x7D, 0xEB, 0x1D, 0x4A, 0xB3, 0x83, 0x76, 0xB8, 0x25, 0x6D, 0xA8, 0x55, 0x10])
    /// SHA256("SecureMessage"), the salt for the four SecureMessage keys.
    static let secureMessageSalt = Data(SHA256.hash(data: Data("SecureMessage".utf8)))

    static func hkdf(ikm: Data, salt: Data, info: Data, length: Int) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: info, outputByteCount: length)
        return key.withUnsafeBytes { Data($0) }
    }

    /// Which end of the connection a key set is for. Mydroid is always `.server` (the receiver); `.client` exists for tests.
    enum Role { case server, client }

    struct SessionKeys {
        /// The 4-digit PIN both devices show (derived from the UKEY2 authentication string).
        let pin: String
        let authString: Data
        let encryptKey: Data
        let decryptKey: Data
        let sendHmac: SymmetricKey
        let recvHmac: SymmetricKey
    }

    /// UKEY2 step "deriving the authentication string and the next protocol secret", then the D2D keys, then the four SecureMessage keys.
    /// `sharedX` is the x coordinate of the ECDH shared point (32 bytes); `clientInit` and `serverInit` are the raw serialized
    /// `Ukey2Message`s exactly as they went over the wire (without the length prefix).
    static func deriveKeys(sharedX: Data, clientInit: Data, serverInit: Data, role: Role) -> SessionKeys {
        let derivedSecret = Data(SHA256.hash(data: sharedX))
        let info = clientInit + serverInit
        let auth = hkdf(ikm: derivedSecret, salt: Data("UKEY2 v1 auth".utf8), info: info, length: 32)
        let next = hkdf(ikm: derivedSecret, salt: Data("UKEY2 v1 next".utf8), info: info, length: 32)
        let d2dClient = hkdf(ikm: next, salt: d2dSalt, info: Data("client".utf8), length: 32)
        let d2dServer = hkdf(ikm: next, salt: d2dSalt, info: Data("server".utf8), length: 32)
        let clientEnc = hkdf(ikm: d2dClient, salt: secureMessageSalt, info: Data("ENC:2".utf8), length: 32)
        let clientSig = hkdf(ikm: d2dClient, salt: secureMessageSalt, info: Data("SIG:1".utf8), length: 32)
        let serverEnc = hkdf(ikm: d2dServer, salt: secureMessageSalt, info: Data("ENC:2".utf8), length: 32)
        let serverSig = hkdf(ikm: d2dServer, salt: secureMessageSalt, info: Data("SIG:1".utf8), length: 32)
        switch role {
        case .server:
            return SessionKeys(pin: pin(from: auth), authString: auth, encryptKey: serverEnc, decryptKey: clientEnc,
                               sendHmac: SymmetricKey(data: serverSig), recvHmac: SymmetricKey(data: clientSig))
        case .client:
            return SessionKeys(pin: pin(from: auth), authString: auth, encryptKey: clientEnc, decryptKey: serverEnc,
                               sendHmac: SymmetricKey(data: clientSig), recvHmac: SymmetricKey(data: serverSig))
        }
    }

    /// The 4-digit connection PIN (Chromium's `nearby_sharing_service_impl.cc`): a rolling hash of the signed bytes of the auth string.
    static func pin(from auth: Data) -> String {
        var hash = 0
        var multiplier = 1
        for byte in auth {
            hash = (hash + Int(Int8(bitPattern: byte)) * multiplier) % 9973
            multiplier = (multiplier * 31) % 9973
        }
        return String(format: "%04d", abs(hash))
    }

    /// UKEY2's commitment to the ClientFinished message: SHA-512 of its raw serialized `Ukey2Message`.
    static func commitment(clientFinish raw: Data) -> Data { Data(SHA512.hash(data: raw)) }

    // MARK: Public key encoding (x and y as Java BigInteger-style signed big-endian integers)

    static func signedBytes(_ unsigned: Data) -> Data {
        var d = Data(unsigned.drop { $0 == 0 })
        if d.isEmpty { d = Data([0]) }
        if d[d.startIndex] & 0x80 != 0 { d.insert(0, at: d.startIndex) }
        return d
    }

    static func encode(publicKey: P256.KeyAgreement.PublicKey) -> QS.Secure.PublicKey {
        let raw = publicKey.x963Representation          // 0x04 | X (32) | Y (32)
        return QS.Secure.PublicKey(x: signedBytes(raw.subdata(in: 1..<33)), y: signedBytes(raw.subdata(in: 33..<65)))
    }

    /// Accepts coordinates with a leading sign byte or leading zeros stripped.
    static func decodePublicKey(_ k: QS.Secure.PublicKey) throws -> P256.KeyAgreement.PublicKey {
        func fixed(_ d: Data) throws -> Data {
            var v = Data(d.drop { $0 == 0 })
            guard v.count <= 32 else { throw QSCryptoError.badPublicKey }
            if v.count < 32 { v = Data(repeating: 0, count: 32 - v.count) + v }
            return v
        }
        do {
            return try P256.KeyAgreement.PublicKey(x963Representation: Data([0x04]) + fixed(k.x) + fixed(k.y))
        } catch {
            throw QSCryptoError.badPublicKey
        }
    }

    static func sharedX(_ priv: P256.KeyAgreement.PrivateKey, _ peer: P256.KeyAgreement.PublicKey) throws -> Data {
        let secret = try priv.sharedSecretFromKeyAgreement(with: peer)
        return secret.withUnsafeBytes { Data($0) }
    }

    // MARK: AES-256-CBC with PKCS#7 padding

    /// Encrypting pads with PKCS#7. Decrypting removes the padding by hand and rejects anything malformed, because CommonCrypto's
    /// own check is lenient on current macOS.
    static func aesCBC(encrypt: Bool, key: Data, iv: Data, input: Data) throws -> Data {
        guard key.count == 32, iv.count == 16 else { throw QSCryptoError.badMessage("key or iv size") }
        if !encrypt, input.isEmpty || input.count % 16 != 0 { throw QSCryptoError.badMessage("ciphertext size") }
        var out = Data(count: input.count + kCCBlockSizeAES128)
        var written = 0
        let options = encrypt ? CCOptions(kCCOptionPKCS7Padding) : CCOptions(0)
        let status: CCCryptorStatus = out.withUnsafeMutableBytes { outPtr in
            input.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), options,
                                keyPtr.baseAddress, 32, ivPtr.baseAddress,
                                inPtr.baseAddress, input.count, outPtr.baseAddress, outPtr.count, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw QSCryptoError.cipherFailure(status) }
        var result = out.prefix(written)
        if !encrypt {
            guard let n = result.last, n >= 1, n <= 16, result.count >= Int(n), result.suffix(Int(n)).allSatisfy({ $0 == n }) else {
                throw QSCryptoError.badMessage("padding")
            }
            result = result.dropLast(Int(n))
        }
        return Data(result)
    }
}

/// The server half of UKEY2 for P256_SHA512 + AES_256_CBC-HMAC_SHA256.
final class QSServerHandshake {
    enum Failure: Error { case alert(QS.Ukey2.AlertType) }

    private let privateKey = P256.KeyAgreement.PrivateKey()
    private var commitment: Data?
    private var clientInitRaw: Data?
    private var serverInitRaw: Data?

    /// Handles the raw `Ukey2Message` ClientInit and returns the raw ServerInit message to send.
    func handleClientInit(_ raw: Data) throws -> Data {
        let msg: QS.Ukey2.Message
        do { msg = try QS.Ukey2.Message(raw) } catch { throw Failure.alert(.badMessage) }
        guard let type = msg.type, let data = msg.data else { throw Failure.alert(.badMessage) }
        guard type == QS.Ukey2.MessageType.clientInit.rawValue else { throw Failure.alert(.badMessageType) }
        let ci: QS.Ukey2.ClientInit
        do { ci = try QS.Ukey2.ClientInit(data) } catch { throw Failure.alert(.badMessageData) }
        guard ci.version == 1 else { throw Failure.alert(.badVersion) }
        guard ci.random?.count == 32 else { throw Failure.alert(.badRandom) }
        guard let c = ci.commitments.first(where: { $0.cipher == QS.Ukey2.handshakeCipherP256Sha512 }) else { throw Failure.alert(.badHandshakeCipher) }
        guard ci.nextProtocol == QS.Ukey2.nextProtocol else { throw Failure.alert(.badNextProtocol) }
        commitment = c.commitment
        clientInitRaw = raw
        var random = Data(count: 32)
        let rc = random.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard rc == errSecSuccess else { throw Failure.alert(.internalError) }
        let serverInit = QS.Ukey2.ServerInit(version: 1, random: random, handshakeCipher: QS.Ukey2.handshakeCipherP256Sha512,
                                             publicKey: QSCrypto.encode(publicKey: privateKey.publicKey).encode())
        let out = QS.Ukey2.Message(type: .serverInit, data: serverInit.encode()).encode()
        serverInitRaw = out
        return out
    }

    /// Handles the raw ClientFinish message and returns the session keys.
    func handleClientFinish(_ raw: Data) throws -> QSCrypto.SessionKeys {
        guard let commitment, let clientInitRaw, let serverInitRaw else { throw Failure.alert(.incorrectMessage) }
        let msg: QS.Ukey2.Message
        do { msg = try QS.Ukey2.Message(raw) } catch { throw Failure.alert(.badMessage) }
        guard msg.type == QS.Ukey2.MessageType.clientFinish.rawValue, let data = msg.data else { throw Failure.alert(.badMessageType) }
        // The commitment in ClientInit binds the client to this exact ClientFinish.
        guard QSCrypto.commitment(clientFinish: raw) == commitment else { throw Failure.alert(.badMessageData) }
        let peer: P256.KeyAgreement.PublicKey
        do {
            let fin = try QS.Ukey2.ClientFinished(data)
            guard let keyBytes = fin.publicKey else { throw Failure.alert(.badPublicKey) }
            peer = try QSCrypto.decodePublicKey(try QS.Secure.PublicKey(keyBytes))
        } catch let f as Failure { throw f } catch { throw Failure.alert(.badPublicKey) }
        guard let x = try? QSCrypto.sharedX(privateKey, peer) else { throw Failure.alert(.badPublicKey) }
        return QSCrypto.deriveKeys(sharedX: x, clientInit: clientInitRaw, serverInit: serverInitRaw, role: .server)
    }
}

/// The SecureMessage layer: AES-256-CBC, HMAC-SHA256, and a per-direction sequence number that starts at 1.
struct QSSecureChannel {
    private let keys: QSCrypto.SessionKeys
    private var sendSeq: Int32 = 0
    private var recvSeq: Int32 = 0

    init(keys: QSCrypto.SessionKeys) { self.keys = keys }

    /// Wraps a serialized `OfflineFrame` in a SecureMessage.
    mutating func seal(_ offlineFrame: Data) throws -> Data {
        sendSeq += 1
        let d2d = QS.Secure.DeviceToDevice(message: offlineFrame, sequenceNumber: sendSeq).encode()
        var iv = Data(count: 16)
        let rc = iv.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard rc == errSecSuccess else { throw QSCryptoError.badMessage("random") }
        let body = try QSCrypto.aesCBC(encrypt: true, key: keys.encryptKey, iv: iv, input: d2d)
        let hb = QS.Secure.HeaderAndBody(iv: iv, publicMetadata: QS.Secure.gcmMetadata(), body: body).encode()
        let sig = Data(HMAC<SHA256>.authenticationCode(for: hb, using: keys.sendHmac))
        return QS.Secure.Message(headerAndBody: hb, signature: sig).encode()
    }

    /// Verifies, decrypts and sequence-checks a SecureMessage, returning the inner serialized `OfflineFrame`.
    mutating func open(_ data: Data) throws -> Data {
        let sm = try QS.Secure.Message(data)
        guard let hb = sm.headerAndBody, let sig = sm.signature else { throw QSCryptoError.badMessage("missing header or signature") }
        guard HMAC<SHA256>.isValidAuthenticationCode(sig, authenticating: hb, using: keys.recvHmac) else { throw QSCryptoError.badSignature }
        let parsed = try QS.Secure.HeaderAndBody(hb)
        guard parsed.signatureScheme == QS.Secure.hmacSha256, parsed.encryptionScheme == QS.Secure.aes256Cbc,
              let iv = parsed.iv, let body = parsed.body else { throw QSCryptoError.badMessage("unsupported scheme") }
        let plain = try QSCrypto.aesCBC(encrypt: false, key: keys.decryptKey, iv: iv, input: body)
        let d2d = try QS.Secure.DeviceToDevice(plain)
        guard let inner = d2d.message, let seq = d2d.sequenceNumber else { throw QSCryptoError.badMessage("missing message or sequence") }
        recvSeq += 1
        guard seq == recvSeq else {
            let expected = recvSeq
            recvSeq -= 1
            throw QSCryptoError.badSequence(expected: expected, got: seq)
        }
        return inner
    }
}

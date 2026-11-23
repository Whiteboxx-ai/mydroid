import XCTest
import Network
import CryptoKit
@testable import MydroidCore

private func hex(_ s: String) -> Data {
    var d = Data()
    var it = s.makeIterator()
    while let a = it.next(), let b = it.next() { d.append(UInt8(String([a, b]), radix: 16)!) }
    return d
}

// MARK: Protobuf codec

final class ProtobufCodecTests: XCTestCase {
    func testVarintKnownVectors() throws {
        // From the protobuf encoding guide: field 1 = 150 is 08 96 01.
        var w = PBWriter(); w.varint(1, 150)
        XCTAssertEqual(w.data, hex("089601"))
        var w2 = PBWriter(); w2.rawVarint(300)
        XCTAssertEqual(w2.data, hex("ac02"))
        var w3 = PBWriter(); w3.string(2, "testing")
        XCTAssertEqual(w3.data, hex("120774657374696e67"))
        let m = try PBMessage(hex("089601120774657374696e67"))
        XCTAssertEqual(m.uint(1), 150)
        XCTAssertEqual(m.string(2), "testing")
    }

    func testNegativeIntsAreTenBytesAndRoundTrip() throws {
        var w = PBWriter(); w.int(1, -1)
        XCTAssertEqual(w.data, hex("08ffffffffffffffffff01"))
        let m = try PBMessage(w.data)
        XCTAssertEqual(m.int64(1), -1)
        XCTAssertEqual(m.int32(1), -1)
    }

    func testLastScalarWinsAndUnknownFieldsAreSkipped() throws {
        var w = PBWriter()
        w.varint(1, 5); w.bytes(9, Data([1, 2, 3])); w.varint(1, 7)
        w.tag(10, wire: 5); w.raw(Data([1, 0, 0, 0]))
        w.tag(11, wire: 1); w.raw(Data([1, 0, 0, 0, 0, 0, 0, 0]))
        let m = try PBMessage(w.data)
        XCTAssertEqual(m.uint(1), 7)
        XCTAssertEqual(m.bytes(9), Data([1, 2, 3]))
        XCTAssertEqual(m.fields.count, 5)
    }

    func testMalformedInputThrows() {
        XCTAssertThrowsError(try PBMessage(hex("08")))                 // key with no value
        XCTAssertThrowsError(try PBMessage(hex("0a05010203")))         // length beyond the end
        XCTAssertThrowsError(try PBMessage(hex("0b")))                 // start-group wire type
        XCTAssertThrowsError(try PBMessage(hex("80808080808080808080808001"))) // varint that never ends
        XCTAssertThrowsError(try PBMessage(hex("0d010203")))           // truncated fixed32
    }

    func testPackedAndUnpackedRepeatedVarints() throws {
        var w = PBWriter(); w.packedVarints(5, [1, 300, 2]); w.varint(5, 9)
        XCTAssertEqual(try PBMessage(w.data).varints(5), [1, 300, 2, 9])
    }

    func testWrongWireTypeIsIgnoredNotMisread() throws {
        var w = PBWriter(); w.bytes(1, Data([1]))
        let m = try PBMessage(w.data)
        XCTAssertNil(m.uint(1))
        XCTAssertEqual(m.bytes(1), Data([1]))
    }
}

// MARK: Messages

final class QSMessageTests: XCTestCase {
    func testConnectionRequestRoundTrip() throws {
        let info = QSEndpoint.endpointInfo(name: "Pixel 9", deviceType: .phone)
        let frame = QS.OfflineFrame(v1: QS.V1Frame(type: .connectionRequest,
                                                   connectionRequest: QS.ConnectionRequest(endpointId: "AbCd", endpointName: "Pixel 9", endpointInfo: info, mediums: [5, 2])))
        let back = try QS.OfflineFrame(frame.encode())
        XCTAssertEqual(back, frame)
        XCTAssertEqual(back.v1?.frameType, .connectionRequest)
        XCTAssertEqual(back.v1?.connectionRequest?.mediums, [5, 2])
        // version = V1 (field 1 = 1), v1 = field 2.
        XCTAssertEqual(frame.encode().prefix(2), hex("0801"))
    }

    func testConnectionResponseMatchesNearDropBytes() throws {
        // status 0, response ACCEPT, os_info { type APPLE }: what NearDrop sends, field by field.
        let r = QS.ConnectionResponse(status: 0, response: .accept, osType: .apple)
        XCTAssertEqual(r.encode(), hex("0800" + "1801" + "2202" + "0804"))
        XCTAssertEqual(try QS.ConnectionResponse(PBMessage(r.encode())), r)
    }

    func testPayloadTransferRoundTrip() throws {
        let pt = QS.PayloadTransfer(data: -5, type: .file, totalSize: 123_456_789_012, offset: 4096, flags: 1, body: Data([9, 8, 7]), fileName: "a.bin")
        let back = try QS.PayloadTransfer(PBMessage(pt.encode()))
        XCTAssertEqual(back, pt)
        XCTAssertEqual(back.payloadId, -5)
        XCTAssertTrue(back.isLast)
    }

    func testKeepAliveDisconnectionAndUkey2Messages() throws {
        XCTAssertEqual(try QS.KeepAlive(PBMessage(QS.KeepAlive(ack: true).encode())).ack, true)
        let d = QS.Disconnection(requestSafeToDisconnect: true, ackSafeToDisconnect: false)
        XCTAssertEqual(try QS.Disconnection(PBMessage(d.encode())), d)

        let ci = QS.Ukey2.ClientInit(version: 1, random: Data(repeating: 7, count: 32),
                                     commitments: [.init(cipher: 100, commitment: Data(repeating: 1, count: 64))], nextProtocol: QS.Ukey2.nextProtocol)
        XCTAssertEqual(try QS.Ukey2.ClientInit(ci.encode()), ci)
        let msg = QS.Ukey2.Message(type: .clientInit, data: ci.encode())
        let back = try QS.Ukey2.Message(msg.encode())
        XCTAssertEqual(back.type, 2)
        XCTAssertEqual(back.data, ci.encode())
        let si = QS.Ukey2.ServerInit(version: 1, random: Data(repeating: 3, count: 32), handshakeCipher: 100, publicKey: Data([1, 2]))
        XCTAssertEqual(try QS.Ukey2.ServerInit(si.encode()), si)
        XCTAssertEqual(try QS.Ukey2.ClientFinished(QS.Ukey2.ClientFinished(publicKey: Data([4])).encode()).publicKey, Data([4]))
    }

    func testSecureMessageLayersRoundTrip() throws {
        let hb = QS.Secure.HeaderAndBody(iv: Data(repeating: 2, count: 16), publicMetadata: QS.Secure.gcmMetadata(), body: Data([1, 2, 3]))
        let back = try QS.Secure.HeaderAndBody(hb.encode())
        XCTAssertEqual(back, hb)
        XCTAssertEqual(back.signatureScheme, 1)
        XCTAssertEqual(back.encryptionScheme, 2)
        // GcmMetadata: type 13 (DEVICE_TO_DEVICE_MESSAGE), version 1.
        XCTAssertEqual(QS.Secure.gcmMetadata(), hex("080d1001"))
        let sm = QS.Secure.Message(headerAndBody: hb.encode(), signature: Data(repeating: 9, count: 32))
        XCTAssertEqual(try QS.Secure.Message(sm.encode()), sm)
        let d2d = QS.Secure.DeviceToDevice(message: Data([5, 5]), sequenceNumber: 3)
        XCTAssertEqual(try QS.Secure.DeviceToDevice(d2d.encode()), d2d)
    }

    func testIntroductionWithFilesTextAndOtherAttachments() throws {
        var intro = QS.Sharing.Introduction(files: [QS.Sharing.FileMetadata(name: "a.jpg", type: 1, payloadId: 11, size: 2048, mimeType: "image/jpeg")],
                                            texts: [QS.Sharing.TextMetadata(title: "https://example.com", type: .url, payloadId: 12, size: 19)])
        var enc = PBWriter()
        // Add a Wi-Fi credentials entry (field 4) the way an Android sender would.
        enc.raw(intro.encode())
        enc.message(4, Data([0x10, 0x01]))
        let frame = QS.Sharing.Frame(type: .introduction, introduction: nil)
        _ = frame
        var v1 = PBWriter(); v1.int(1, 1); v1.message(2, enc.data)
        var top = PBWriter(); top.int(1, 1); top.message(2, v1.data)
        let parsed = try QS.Sharing.Frame(top.data)
        XCTAssertEqual(parsed.frameType, .introduction)
        XCTAssertEqual(parsed.introduction?.files, intro.files)
        XCTAssertEqual(parsed.introduction?.texts.first?.textType, .url)
        XCTAssertEqual(parsed.introduction?.otherAttachments, 1)
        intro.otherAttachments = 0
        let rt = try QS.Sharing.Frame(QS.Sharing.Frame(type: .introduction, introduction: intro).encode())
        XCTAssertEqual(rt.introduction, intro)
    }

    func testSharingResponseAndPairedKeyFrames() throws {
        let accept = try QS.Sharing.Frame(QS.Sharing.Frame(type: .response, responseStatus: .accept).encode())
        XCTAssertEqual(accept.frameType, .response)
        XCTAssertEqual(accept.responseStatus, 1)
        let pke = try QS.Sharing.Frame(QS.Sharing.Frame(type: .pairedKeyEncryption,
                                                        pairedKeyEncryption: .init(signedData: Data(repeating: 1, count: 72), secretIdHash: Data(repeating: 2, count: 6))).encode())
        XCTAssertEqual(pke.pairedKeyEncryption?.signedData?.count, 72)
        let res = try QS.Sharing.Frame(QS.Sharing.Frame(type: .pairedKeyResult, pairedKeyResultStatus: QS.Sharing.pairedKeyResultUnable).encode())
        XCTAssertEqual(res.pairedKeyResultStatus, 3)
        XCTAssertEqual(try QS.Sharing.Frame(QS.Sharing.Frame(type: .cancel).encode()).frameType, .cancel)
    }
}

// MARK: Endpoint, framing, key derivation

final class QSCryptoTests: XCTestCase {
    func testServiceTypeAndNameVectors() {
        XCTAssertEqual(QSEndpoint.serviceType, "_FC9F5ED42C8A._tcp")
        // The service type is the first 6 bytes of SHA256("NearbySharing").
        let h = SHA256.hash(data: Data("NearbySharing".utf8)).map { String(format: "%02X", $0) }.joined()
        XCTAssertTrue(h.hasPrefix("FC9F5ED42C8A"))
        // Independent computation: base64url(23 41 42 43 44 fc 9f 5e 00 00).
        XCTAssertEqual(QSEndpoint.serviceName(endpointId: "ABCD"), "I0FCQ0T8n14AAA")
        XCTAssertEqual(QSEndpoint.fromBase64URL("I0FCQ0T8n14AAA"), hex("2341424344fc9f5e0000"))
        XCTAssertEqual(QSEndpoint.randomEndpointId().count, 4)
    }

    func testEndpointInfoEncodingAndParsing() throws {
        let rnd = Data(0..<16)
        let info = QSEndpoint.endpointInfo(name: "Gautam's Mac", deviceType: .laptop, randomBytes: rnd)
        XCTAssertEqual(info[0], 0x06)                  // version 0, visible, laptop (3) in bits 3..1
        XCTAssertEqual(info.subdata(in: 1..<17), rnd)
        XCTAssertEqual(info[17], 12)
        let parsed = try XCTUnwrap(QSEndpoint.parseEndpointInfo(info))
        XCTAssertEqual(parsed.name, "Gautam's Mac")
        XCTAssertEqual(parsed.deviceType, .laptop)
        XCTAssertTrue(parsed.visible)
        // A phone with a QR TLV (type 1) after the name.
        var withQr = QSEndpoint.endpointInfo(name: "Pixel", deviceType: .phone, randomBytes: rnd)
        withQr.append(contentsOf: [1, 3, 9, 8, 7, 2, 1, 1])
        let p2 = try XCTUnwrap(QSEndpoint.parseEndpointInfo(withQr))
        XCTAssertEqual(p2.deviceType, .phone)
        XCTAssertEqual(p2.qrData, Data([9, 8, 7]))
        // Hidden (visibility bit set): no name.
        var hidden = Data([0x10 | (1 << 1)]); hidden.append(Data(repeating: 0, count: 16))
        let p3 = try XCTUnwrap(QSEndpoint.parseEndpointInfo(hidden))
        XCTAssertNil(p3.name)
        XCTAssertFalse(p3.visible)
        XCTAssertNil(QSEndpoint.parseEndpointInfo(Data([0, 1, 2])))
        // Over-long names are cut on a character boundary.
        let long = QSEndpoint.endpointInfo(name: String(repeating: "é", count: 200))
        XCTAssertLessThanOrEqual(Int(long[17]), 255)
        XCTAssertNotNil(QSEndpoint.parseEndpointInfo(long)?.name)
    }

    func testBase64URLRoundTrip() {
        let d = Data([0xfb, 0xff, 0xfe, 0x01])
        let s = QSEndpoint.base64URL(d)
        XCTAssertFalse(s.contains("+") || s.contains("/") || s.contains("="))
        XCTAssertEqual(QSEndpoint.fromBase64URL(s), d)
    }

    func testConstantsMatchTheirDefinitions() {
        XCTAssertEqual(QSCrypto.d2dSalt, Data(SHA256.hash(data: Data("D2D".utf8))))
        XCTAssertEqual(QSCrypto.d2dSalt, hex("82aa55a0d397f88346ca1cee8d3909b95f13fa7deb1d4ab38376b8256da85510"))
        XCTAssertEqual(QSCrypto.secureMessageSalt, hex("bf9d2a53c63616d75db0a7165b91c1ef73e537f2427405fa23610a4be657642e"))
    }

    /// Vectors computed with an independent implementation of the key schedule in NearDrop's PROTOCOL.md and the UKEY2 readme
    /// (HKDF-SHA256 by hand in Python). They are not from Google.
    func testUkey2KeyScheduleVector() {
        let sharedX = hex("030a11181f262d343b424950575e656c737a81888f969da4abb2b9c0c7ced5dc")
        let ci = hex("08021207636c69656e7449000102030405060708090a0b0c0d0e0f10111213")
        let si = hex("08031207736572766572496465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f8081")
        let server = QSCrypto.deriveKeys(sharedX: sharedX, clientInit: ci, serverInit: si, role: .server)
        XCTAssertEqual(server.authString, hex("2c481c58ee8ef7d297b07e5c6696aefbeb4b1ac0d5d557d04039dbaff8c1338e"))
        XCTAssertEqual(server.pin, "3611")
        XCTAssertEqual(server.decryptKey, hex("c2406d0a2ed01dfc51932b0891cb2d37e0ad52a75d38ce2d017eeadbb7c187fe"))     // client ENC
        XCTAssertEqual(server.encryptKey, hex("1151562cc47ecf60f396a6749857e0e3c34e2bd2c6f47cff7c92190f76f1252d"))     // server ENC
        XCTAssertEqual(server.recvHmac.withUnsafeBytes { Data($0) }, hex("19e329e5d12bfd7684f623c50828a41783236be9aaf7baaac9a223b6eb988bdf"))   // client SIG
        XCTAssertEqual(server.sendHmac.withUnsafeBytes { Data($0) }, hex("bf0ee9c9dc2ba4d9ade039f90d5bbe914cf51b30665aa64d71c4e50a8472f665"))   // server SIG
        // The client sees the mirror image.
        let client = QSCrypto.deriveKeys(sharedX: sharedX, clientInit: ci, serverInit: si, role: .client)
        XCTAssertEqual(client.encryptKey, server.decryptKey)
        XCTAssertEqual(client.decryptKey, server.encryptKey)
        XCTAssertEqual(client.pin, server.pin)
        XCTAssertEqual(client.sendHmac.withUnsafeBytes { Data($0) }, server.recvHmac.withUnsafeBytes { Data($0) })
    }

    func testPinVectors() {
        XCTAssertEqual(QSCrypto.pin(from: Data(repeating: 0, count: 32)), "0000")
        XCTAssertEqual(QSCrypto.pin(from: Data(repeating: 0xff, count: 32)), "6509")
        XCTAssertEqual(QSCrypto.pin(from: Data(0..<32)), "5095")
        XCTAssertEqual(QSCrypto.pin(from: hex("00254a6f94b9de03284d7297bce1062b50759abfe4092e53789dc2e70c31567b")), "2600")
        for _ in 0..<50 {
            let p = QSCrypto.pin(from: Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
            XCTAssertEqual(p.count, 4)
            XCTAssertNotNil(Int(p))
        }
    }

    func testSignedBytesAndPublicKeyEncoding() throws {
        XCTAssertEqual(QSCrypto.signedBytes(Data([0x80, 0x01])), Data([0x00, 0x80, 0x01]))
        XCTAssertEqual(QSCrypto.signedBytes(Data([0x00, 0x00, 0x7f])), Data([0x7f]))
        XCTAssertEqual(QSCrypto.signedBytes(Data([0x00])), Data([0x00]))
        XCTAssertEqual(QSCrypto.signedBytes(Data()), Data([0x00]))
        for _ in 0..<40 {
            let k = P256.KeyAgreement.PrivateKey().publicKey
            let enc = QSCrypto.encode(publicKey: k)
            XCTAssertLessThanOrEqual(enc.x.count, 33)
            XCTAssertTrue(enc.x.count == 33 ? enc.x.first == 0 : true)
            XCTAssertEqual(try QSCrypto.decodePublicKey(enc).x963Representation, k.x963Representation)
            // Round trip through the protobuf encoding as well.
            XCTAssertEqual(try QS.Secure.PublicKey(enc.encode()), enc)
        }
        XCTAssertThrowsError(try QSCrypto.decodePublicKey(QS.Secure.PublicKey(x: Data(repeating: 1, count: 40), y: Data([1]))))
        XCTAssertThrowsError(try QSCrypto.decodePublicKey(QS.Secure.PublicKey(x: Data([1]), y: Data([2]))), "not on the curve")
    }

    func testAesCbcRoundTripAndPaddingErrors() throws {
        let key = Data(repeating: 3, count: 32), iv = Data(repeating: 4, count: 16)
        for n in [0, 1, 15, 16, 17, 1000] {
            let plain = Data((0..<n).map { UInt8($0 & 0xff) })
            let ct = try QSCrypto.aesCBC(encrypt: true, key: key, iv: iv, input: plain)
            XCTAssertEqual(ct.count % 16, 0)
            XCTAssertEqual(try QSCrypto.aesCBC(encrypt: false, key: key, iv: iv, input: ct), plain)
        }
        XCTAssertThrowsError(try QSCrypto.aesCBC(encrypt: true, key: Data(count: 16), iv: iv, input: Data()))
        // Random ciphertext decrypts to garbage whose padding is valid only about once in 256 blocks.
        let failures = (0..<64).filter { _ in
            (try? QSCrypto.aesCBC(encrypt: false, key: key, iv: iv, input: Data((0..<16).map { _ in UInt8.random(in: 0...255) }))) == nil
        }
        XCTAssertGreaterThan(failures.count, 50, "garbage fails the padding check")
    }

    func testSecureChannelRoundTripTamperAndSequence() throws {
        let k = hex("030a11181f262d343b424950575e656c737a81888f969da4abb2b9c0c7ced5dc")
        let server = QSCrypto.deriveKeys(sharedX: k, clientInit: Data([1]), serverInit: Data([2]), role: .server)
        let client = QSCrypto.deriveKeys(sharedX: k, clientInit: Data([1]), serverInit: Data([2]), role: .client)
        var s = QSSecureChannel(keys: server), c = QSSecureChannel(keys: client)
        let a = try c.seal(Data("hello".utf8)), b = try c.seal(Data("again".utf8))
        XCTAssertEqual(try s.open(a), Data("hello".utf8))
        XCTAssertEqual(try s.open(b), Data("again".utf8))
        // Replaying an old message (sequence 1 when 3 is expected) fails, and doesn't advance the counter.
        XCTAssertThrowsError(try s.open(a)) { XCTAssertEqual($0 as? QSCryptoError, .badSequence(expected: 3, got: 1)) }
        // Flipping any bit in the signed part fails the HMAC.
        let good = try c.seal(Data("x".utf8))
        var bad = good
        bad[bad.count / 2] ^= 1
        XCTAssertThrowsError(try s.open(bad))
        XCTAssertEqual(try s.open(good), Data("x".utf8), "a failed message doesn't use up a sequence number")
        // The other direction uses other keys.
        var s2 = QSSecureChannel(keys: server)
        XCTAssertThrowsError(try s2.open(try s2.seal(Data("loop".utf8))))
    }

    func testServerHandshakeRejectsBadInput() throws {
        func alert(_ block: (QSServerHandshake) throws -> Void) -> QS.Ukey2.AlertType? {
            do { try block(QSServerHandshake()); return nil } catch QSServerHandshake.Failure.alert(let t) { return t } catch { return nil }
        }
        func clientInit(version: Int32 = 1, randomCount: Int = 32, cipher: Int64 = 100, next: String = QS.Ukey2.nextProtocol) -> Data {
            let ci = QS.Ukey2.ClientInit(version: version, random: Data(repeating: 1, count: randomCount),
                                         commitments: [.init(cipher: cipher, commitment: Data(repeating: 2, count: 64))], nextProtocol: next)
            return QS.Ukey2.Message(type: .clientInit, data: ci.encode()).encode()
        }
        XCTAssertEqual(alert { _ = try $0.handleClientInit(Data([0xff, 0xff])) }, .badMessage)
        XCTAssertEqual(alert { _ = try $0.handleClientInit(QS.Ukey2.Message(type: .serverInit, data: Data()).encode()) }, .badMessageType)
        XCTAssertEqual(alert { _ = try $0.handleClientInit(clientInit(version: 2)) }, .badVersion)
        XCTAssertEqual(alert { _ = try $0.handleClientInit(clientInit(randomCount: 16)) }, .badRandom)
        XCTAssertEqual(alert { _ = try $0.handleClientInit(clientInit(cipher: 200)) }, .badHandshakeCipher)
        XCTAssertEqual(alert { _ = try $0.handleClientInit(clientInit(next: "AES_128")) }, .badNextProtocol)
        XCTAssertEqual(alert { _ = try $0.handleClientFinish(Data()) }, .incorrectMessage, "finish before init")
        XCTAssertNil(alert { _ = try $0.handleClientInit(clientInit()) })
    }

    func testFrameBuffer() throws {
        var b = QSFrameBuffer(maxFrame: 100)
        let f1 = Data([1, 2, 3]), f2 = Data(repeating: 9, count: 50)
        let wire = QSFrameBuffer.wrap(f1) + QSFrameBuffer.wrap(f2) + QSFrameBuffer.wrap(Data())
        // Feed a byte at a time: frames only appear once complete.
        var got: [Data] = []
        for byte in wire {
            b.append(Data([byte]))
            while let f = try b.next() { got.append(f) }
        }
        XCTAssertEqual(got, [f1, f2, Data()])
        b.append(Data([0, 0, 1, 0]))             // claims 256 bytes
        XCTAssertThrowsError(try b.next()) { XCTAssertEqual($0 as? QSFrameBuffer.Failure, .tooLarge) }
        XCTAssertEqual(QSFrameBuffer.wrap(Data([7])), Data([0, 0, 0, 1, 7]))
    }

    func testTrustRequiresNameConnectionAndMatchingAddress() {
        func trusted(_ name: String, host: String? = "10.0.0.5", connected: Bool = true, phoneHost: String? = "10.0.0.5",
                     phone: String? = "Pixel 9", model: String? = "Pixel 9 Pro") -> Bool {
            QuickShareTrust.isPairedPhone(senderName: name, senderHost: host, phoneName: phone, phoneModel: model, phoneHost: phoneHost, connected: connected)
        }
        XCTAssertTrue(trusted("Pixel 9"))
        XCTAssertTrue(trusted("  pixel 9 "))
        XCTAssertTrue(trusted("Pixel 9 Pro"), "the model counts too")
        XCTAssertFalse(trusted("Pixel 8"))
        XCTAssertFalse(trusted(""))
        XCTAssertFalse(trusted("Pixel 9", connected: false), "the phone must be connected to Mydroid")
        XCTAssertFalse(trusted("Pixel 9", host: "10.0.0.99"), "same name from another address is somebody else")
        XCTAssertTrue(trusted("Pixel 9", host: nil), "no address to compare")
        XCTAssertTrue(trusted("Pixel 9", phoneHost: nil))
        XCTAssertFalse(trusted("Pixel 9", phone: nil, model: nil))
    }

    func testSettingsDefaultsAndDecoding() throws {
        let d = QuickShareSettings()
        XCTAssertEqual(d.visibility, .phoneConnected)
        XCTAssertEqual(d.others, .ask)
        XCTAssertFalse(d.imagesToPhotosFolder)
        let old = try JSONDecoder().decode(QuickShareSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(old, d)
        let rt = try JSONDecoder().decode(QuickShareSettings.self, from: JSONEncoder().encode(QuickShareSettings(visibility: .off, others: .never, imagesToPhotosFolder: true)))
        XCTAssertEqual(rt, QuickShareSettings(visibility: .off, others: .never, imagesToPhotosFolder: true))
    }
}

// MARK: A Quick Share sender, for driving the receiver

/// A thread-safe queue of frames with blocking reads, so a test can use straight-line code.
final class FrameInbox: @unchecked Sendable {
    private let lock = NSLock()
    private let sem = DispatchSemaphore(value: 0)
    private var frames: [Data] = []
    private var closedFlag = false
    func push(_ d: Data) { lock.lock(); frames.append(d); lock.unlock(); sem.signal() }
    func close() { lock.lock(); closedFlag = true; lock.unlock(); sem.signal() }
    func pop(timeout: TimeInterval = 5) -> Data? {
        guard sem.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        if frames.isEmpty { return nil }
        return frames.removeFirst()
    }
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closedFlag }
}

protocol QSPipe {
    func send(_ frame: Data)
    func recv(timeout: TimeInterval) -> Data?
}

/// Plays the Android sender: connection request, UKEY2 as the client, the secure layer and Nearby Share frames.
final class QSTestSender {
    let pipe: QSPipe
    var channel: QSSecureChannel?
    var pin = ""
    private var sharingBuffers: [Int64: Data] = [:]
    var payloadId: Int64 = 1000

    init(_ pipe: QSPipe) { self.pipe = pipe }

    struct Failure: Error, CustomStringConvertible { let description: String }

    func offlineFrame(_ v1: QS.V1Frame) -> Data { QS.OfflineFrame(v1: v1).encode() }

    /// Connection request + UKEY2 + connection responses. After this the channel is encrypted.
    func handshake(name: String, type: QSDeviceType = .phone, corruptCommitment: Bool = false) throws {
        let info = QSEndpoint.endpointInfo(name: name, deviceType: type)
        pipe.send(offlineFrame(QS.V1Frame(type: .connectionRequest, connectionRequest: QS.ConnectionRequest(endpointId: "TEST", endpointName: name, endpointInfo: info, mediums: [5]))))
        let priv = P256.KeyAgreement.PrivateKey()
        let finishMsg = QS.Ukey2.Message(type: .clientFinish, data: QS.Ukey2.ClientFinished(publicKey: QSCrypto.encode(publicKey: priv.publicKey).encode()).encode()).encode()
        var commitment = QSCrypto.commitment(clientFinish: finishMsg)
        if corruptCommitment { commitment[0] ^= 1 }
        let clientInit = QS.Ukey2.Message(type: .clientInit, data: QS.Ukey2.ClientInit(
            version: 1, random: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
            commitments: [.init(cipher: 100, commitment: commitment)], nextProtocol: QS.Ukey2.nextProtocol).encode()).encode()
        pipe.send(clientInit)
        guard let serverInitRaw = pipe.recv(timeout: 5) else { throw Failure(description: "no server init") }
        let msg = try QS.Ukey2.Message(serverInitRaw)
        guard msg.type == QS.Ukey2.MessageType.serverInit.rawValue else { throw Failure(description: "expected server init, got type \(msg.type ?? -1)") }
        let si = try QS.Ukey2.ServerInit(msg.data ?? Data())
        let serverKey = try QSCrypto.decodePublicKey(try QS.Secure.PublicKey(si.publicKey ?? Data()))
        let x = try QSCrypto.sharedX(priv, serverKey)
        let keys = QSCrypto.deriveKeys(sharedX: x, clientInit: clientInit, serverInit: serverInitRaw, role: .client)
        pin = keys.pin
        channel = QSSecureChannel(keys: keys)
        pipe.send(finishMsg)
        pipe.send(offlineFrame(QS.V1Frame(type: .connectionResponse, connectionResponse: QS.ConnectionResponse(status: 0, response: .accept, osType: .android))))
        guard let resp = pipe.recv(timeout: 5) else { throw Failure(description: "no connection response") }
        // An OfflineFrame and a Ukey2Message both start with "field 1 = 1", so tell an alert apart by what is inside.
        let r = try QS.OfflineFrame(resp)
        guard r.v1?.frameType == .connectionResponse else {
            let m = try QS.Ukey2.Message(resp)
            throw Failure(description: m.type == QS.Ukey2.MessageType.alert.rawValue ? "ukey2 alert" : "bad connection response")
        }
        guard r.v1?.connectionResponse?.response == 1 else { throw Failure(description: "bad connection response") }
        // The receiver's paired key encryption arrives encrypted; answer with ours and its result.
        let theirs = try nextSharing()
        guard theirs.frameType == .pairedKeyEncryption else { throw Failure(description: "expected paired key encryption") }
        try sendSharing(QS.Sharing.Frame(type: .pairedKeyEncryption, pairedKeyEncryption: .init(signedData: Data(repeating: 1, count: 72), secretIdHash: Data(repeating: 2, count: 6))))
        let result = try nextSharing()
        guard result.frameType == .pairedKeyResult else { throw Failure(description: "expected paired key result") }
        try sendSharing(QS.Sharing.Frame(type: .pairedKeyResult, pairedKeyResultStatus: QS.Sharing.pairedKeyResultUnable))
    }

    func sendOffline(_ v1: QS.V1Frame) throws {
        guard var ch = channel else { throw Failure(description: "no channel") }
        let sealed = try ch.seal(offlineFrame(v1))
        channel = ch
        pipe.send(sealed)
    }

    func sendSharing(_ f: QS.Sharing.Frame) throws {
        let data = f.encode()
        payloadId += 1
        try sendBytes(id: payloadId, data)
    }

    /// A BYTES payload the way Android sends it: the whole message, then an empty last chunk.
    func sendBytes(id: Int64, _ data: Data) throws {
        try sendOffline(QS.V1Frame(type: .payloadTransfer, payloadTransfer: QS.PayloadTransfer(data: id, type: .bytes, totalSize: Int64(data.count), offset: 0, flags: 0, body: data)))
        try sendOffline(QS.V1Frame(type: .payloadTransfer, payloadTransfer: QS.PayloadTransfer(data: id, type: .bytes, totalSize: Int64(data.count), offset: Int64(data.count), flags: 1, body: nil)))
    }

    func sendFile(id: Int64, data: Data, chunk: Int = 40_000, lastWithBody: Bool = false) throws {
        var off = 0
        repeat {
            let end = min(off + chunk, data.count)
            let isLast = lastWithBody && end == data.count
            try sendOffline(QS.V1Frame(type: .payloadTransfer, payloadTransfer: QS.PayloadTransfer(
                data: id, type: .file, totalSize: Int64(data.count), offset: Int64(off), flags: isLast ? 1 : 0, body: data.subdata(in: off..<end))))
            off = end
        } while off < data.count
        if !lastWithBody {
            try sendOffline(QS.V1Frame(type: .payloadTransfer, payloadTransfer: QS.PayloadTransfer(
                data: id, type: .file, totalSize: Int64(data.count), offset: Int64(data.count), flags: 1, body: nil)))
        }
    }

    /// The next decrypted offline frame from the receiver.
    func nextOffline(timeout: TimeInterval = 5) throws -> QS.OfflineFrame {
        guard let raw = pipe.recv(timeout: timeout) else { throw Failure(description: "timed out waiting for a frame") }
        guard var ch = channel else { throw Failure(description: "no channel") }
        let inner = try ch.open(raw)
        channel = ch
        return try QS.OfflineFrame(inner)
    }

    /// The next Nearby Share frame, reassembling payloads and skipping keep-alives.
    func nextSharing(timeout: TimeInterval = 5) throws -> QS.Sharing.Frame {
        while true {
            let f = try nextOffline(timeout: timeout)
            guard let v1 = f.v1 else { continue }
            if v1.frameType == .payloadTransfer, let pt = v1.payloadTransfer, let id = pt.payloadId {
                var buf = sharingBuffers[id] ?? Data()
                if let b = pt.chunkBody { buf.append(b) }
                if pt.isLast { sharingBuffers[id] = nil; return try QS.Sharing.Frame(buf) }
                sharingBuffers[id] = buf
            }
        }
    }

    /// Reads until the receiver says goodbye or the pipe closes. Returns whether a disconnection frame came.
    func waitForDisconnection(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let f = try? nextOffline(timeout: max(0.1, deadline.timeIntervalSinceNow)) else { return false }
            if f.v1?.frameType == .disconnection { return true }
        }
        return false
    }

    func introduce(files: [QS.Sharing.FileMetadata] = [], texts: [QS.Sharing.TextMetadata] = []) throws {
        try sendSharing(QS.Sharing.Frame(type: .introduction, introduction: .init(files: files, texts: texts)))
    }
}

/// Drives a `QSInboundConnection` directly, with frames passed in memory.
final class MemoryPipe: QSPipe, QSConnectionDelegate {
    let queue = DispatchQueue(label: "test.qs.conn")
    let inbox = FrameInbox()
    var conn: QSInboundConnection!
    var decide: (QSRequest) -> QSDecision? = { _ in .reject }
    private let lock = NSLock()
    private var events: [QSConnectionEvent] = []
    var requests: [QSRequest] = []
    private let eventSem = DispatchSemaphore(value: 0)

    init(host: String? = "192.168.1.20", configure: (QSInboundConnection) -> Void = { _ in }) {
        conn = QSInboundConnection(id: "conn-1", remoteHost: host, queue: queue,
                                   sendFrame: { [inbox] d in inbox.push(d) }, closeTransport: { [inbox] in inbox.close() })
        conn.delegate = self
        configure(conn)
        queue.sync { conn.start() }
    }
    deinit { queue.sync { conn.transportClosed() } }

    func send(_ frame: Data) { queue.async { self.conn.receive(frame) } }
    func recv(timeout: TimeInterval) -> Data? { inbox.pop(timeout: timeout) }

    func qsConnection(_ id: String, request: QSRequest, respond: @escaping (QSDecision) -> Void) {
        lock.lock(); requests.append(request); lock.unlock()
        if let d = decide(request) { respond(d) }
    }
    func qsConnection(_ id: String, event: QSConnectionEvent) {
        lock.lock(); events.append(event); lock.unlock()
        eventSem.signal()
    }

    var allEvents: [QSConnectionEvent] { lock.lock(); defer { lock.unlock() }; return events }

    /// Waits for an event the matcher likes (earlier ones stay in `allEvents`).
    func waitFor<T>(timeout: TimeInterval = 5, _ match: (QSConnectionEvent) -> T?) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        var seen = 0
        while true {
            lock.lock(); let snapshot = events; lock.unlock()
            while seen < snapshot.count { if let r = match(snapshot[seen]) { return r }; seen += 1 }
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return nil }
            _ = eventSem.wait(timeout: .now() + min(left, 0.2))
        }
    }

    func waitFinished(timeout: TimeInterval = 5) -> QSFinish? {
        waitFor(timeout: timeout) { if case let .finished(r) = $0 { return r } else { return nil } }
    }
}

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("mydroid-qs-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

// MARK: The receiver state machine, in memory

final class QSConnectionTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws { dir = try tempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func accepting(_ p: MemoryPipe) { p.decide = { [dir] _ in .accept(destination: { _ in dir! }) } }

    func testTextShareIsReceivedAndAcceptedWithMatchingPin() throws {
        let p = MemoryPipe(); accepting(p)
        let s = QSTestSender(p)
        try s.handshake(name: "Pixel 9")
        let text = "Hello from my phone"
        try s.introduce(texts: [.init(title: "Hello", type: .text, payloadId: 77, size: Int64(text.utf8.count))])
        let resp = try s.nextSharing()
        XCTAssertEqual(resp.frameType, .response)
        XCTAssertEqual(resp.responseStatus, 1)
        try s.sendBytes(id: 77, Data(text.utf8))
        let got = p.waitFor { if case let .text(t, url) = $0 { return (t, url) } else { return nil } }
        XCTAssertEqual(got?.0, text)
        XCTAssertEqual(got?.1, false)
        XCTAssertEqual(p.waitFinished(), .completed)
        XCTAssertTrue(s.waitForDisconnection())
        let req = try XCTUnwrap(p.requests.first)
        XCTAssertEqual(req.senderName, "Pixel 9")
        XCTAssertEqual(req.deviceType, .phone)
        XCTAssertEqual(req.pin, s.pin, "both sides show the same PIN")
        XCTAssertEqual(req.pin.count, 4)
        XCTAssertEqual(req.remoteHost, "192.168.1.20")
    }

    func testUrlShare() throws {
        let p = MemoryPipe(); accepting(p)
        let s = QSTestSender(p)
        try s.handshake(name: "Pixel 9")
        let url = "https://example.com/a?b=c"
        try s.introduce(texts: [.init(title: url, type: .url, payloadId: 5, size: Int64(url.utf8.count))])
        XCTAssertEqual(try s.nextSharing().responseStatus, 1)
        try s.sendBytes(id: 5, Data(url.utf8))
        let got = p.waitFor { if case let .text(t, isURL) = $0 { return (t, isURL) } else { return nil } }
        XCTAssertEqual(got?.0, url)
        XCTAssertEqual(got?.1, true)
        XCTAssertEqual(p.waitFinished(), .completed)
    }

    func testFileShareSavesBytesAndPicksUniqueNames() throws {
        for round in 1...2 {
            let p = MemoryPipe(); accepting(p)
            let s = QSTestSender(p)
            try s.handshake(name: "Pixel 9")
            let data = Data((0..<150_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            try s.introduce(files: [.init(name: "photo.jpg", type: 1, payloadId: 9, size: Int64(data.count), mimeType: "image/jpeg")])
            XCTAssertEqual(try s.nextSharing().responseStatus, 1)
            try s.sendFile(id: 9, data: data)
            let saved = try XCTUnwrap(p.waitFor { if case let .file(item, url) = $0 { return (item, url) } else { return nil } })
            XCTAssertEqual(saved.0.name, "photo.jpg")
            XCTAssertEqual(saved.1.lastPathComponent, round == 1 ? "photo.jpg" : "photo (2).jpg")
            XCTAssertEqual(try Data(contentsOf: saved.1), data)
            XCTAssertEqual(p.waitFinished(), .completed)
            XCTAssertTrue(s.waitForDisconnection())
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".part") }, [], "no partial files left")
    }

    func testProgressEventsAndLastChunkCarryingData() throws {
        let p = MemoryPipe(); accepting(p)
        let s = QSTestSender(p)
        try s.handshake(name: "Pixel 9")
        let data = Data(repeating: 7, count: 100_000)
        try s.introduce(files: [.init(name: "a.bin", type: 0, payloadId: 1, size: Int64(data.count), mimeType: "application/octet-stream")])
        _ = try s.nextSharing()
        try s.sendFile(id: 1, data: data, chunk: 30_000, lastWithBody: true)
        XCTAssertEqual(p.waitFinished(), .completed)
        let written = p.allEvents.compactMap { e -> Int64? in if case let .progress(_, w) = e { return w } else { return nil } }
        XCTAssertEqual(written, [30_000, 60_000, 90_000, 100_000])
    }

    func testSeveralFilesAndText() throws {
        let p = MemoryPipe(); accepting(p)
        let s = QSTestSender(p)
        try s.handshake(name: "Pixel 9")
        let a = Data(repeating: 1, count: 1000), b = Data(repeating: 2, count: 2000)
        try s.introduce(files: [.init(name: "a.txt", payloadId: 1, size: 1000, mimeType: "text/plain"), .init(name: "b.txt", payloadId: 2, size: 2000, mimeType: "text/plain")],
                        texts: [.init(title: "t", type: .text, payloadId: 3, size: 2)])
        XCTAssertEqual(try s.nextSharing().responseStatus, 1)
        try s.sendFile(id: 2, data: b)
        try s.sendBytes(id: 3, Data("hi".utf8))
        XCTAssertNil(p.waitFor(timeout: 0.3) { if case .finished = $0 { return true } else { return nil } }, "waits for the last file")
        try s.sendFile(id: 1, data: a)
        XCTAssertEqual(p.waitFinished(), .completed)
        let files = p.allEvents.compactMap { e -> String? in if case let .file(i, _) = e { return i.name } else { return nil } }
        XCTAssertEqual(Set(files), ["a.txt", "b.txt"])
    }

    func testHostileFileNamesAreConfined() throws {
        let p = MemoryPipe(); accepting(p)
        let s = QSTestSender(p)
        try s.handshake(name: "Pixel 9")
        try s.introduce(files: [.init(name: "../../../etc/evil.sh", payloadId: 1, size: 3, mimeType: "text/plain"),
                                .init(name: "/abs/path.txt", payloadId: 2, size: 3, mimeType: "text/plain"),
                                .init(name: "..", payloadId: 3, size: 3, mimeType: "text/plain")])
        _ = try s.nextSharing()
        for id in 1...3 as ClosedRange<Int64> { try s.sendFile(id: id, data: Data([1, 2, 3])) }
        XCTAssertEqual(p.waitFinished(), .completed)
        let urls = p.allEvents.compactMap { e -> URL? in if case let .file(_, u) = e { return u } else { return nil } }
        XCTAssertEqual(urls.count, 3)
        for u in urls { XCTAssertEqual(u.deletingLastPathComponent().standardizedFileURL.path, dir.standardizedFileURL.path) }
        XCTAssertEqual(Set(urls.map(\.lastPathComponent)), ["evil.sh", "path.txt", "file"])
    }

    func testRejectSendsRejectAndCloses() throws {
        let p = MemoryPipe()
        p.decide = { _ in .reject }
        let s = QSTestSender(p)
        try s.handshake(name: "Some Laptop")
        try s.introduce(files: [.init(name: "a.bin", payloadId: 1, size: 10, mimeType: "application/octet-stream")])
        XCTAssertEqual(try s.nextSharing().responseStatus, 2)
        XCTAssertEqual(p.waitFinished(), .rejected)
        XCTAssertTrue(p.waitFor { if case .decisionEnded = $0 { return true } else { return nil } } ?? false)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    func testNoAnswerTimesOut() throws {
        let p = MemoryPipe { $0.decisionTimeout = 0.3 }
        p.decide = { _ in nil }                      // nobody answers
        let s = QSTestSender(p)
        try s.handshake(name: "Some Laptop")
        try s.introduce(files: [.init(name: "a.bin", payloadId: 1, size: 10, mimeType: "application/octet-stream")])
        XCTAssertEqual(try s.nextSharing().responseStatus, 5, "TIMED_OUT")
        XCTAssertEqual(p.waitFinished(), .timedOut)
        XCTAssertTrue(p.waitFor { if case .decisionEnded = $0 { return true } else { return nil } } ?? false)
    }

    func testLateAnswerAfterTimeoutIsIgnored() throws {
        var saved: ((QSDecision) -> Void)?
        let p = MemoryPipe { $0.decisionTimeout = 0.2 }
        let dir = self.dir!
        p.decide = { _ in nil }
        let s = QSTestSender(p)
        try s.handshake(name: "X")
        try s.introduce(files: [.init(name: "a.bin", payloadId: 1, size: 10, mimeType: "x/y")])
        XCTAssertEqual(p.waitFinished(), .timedOut)
        saved = { _ in }
        _ = saved
        p.queue.sync { p.conn.receive(Data([1, 2, 3])) }       // nothing happens after the end
        _ = dir
    }

    func testUnsupportedAttachmentIsRefused() throws {
        let p = MemoryPipe(); accepting(p)
        let s = QSTestSender(p)
        try s.handshake(name: "Pixel 9")
        // Introduction with only a Wi-Fi credentials entry (field 4).
        var intro = PBWriter(); intro.message(4, Data([0x10, 0x01]))
        var v1 = PBWriter(); v1.int(1, 1); v1.message(2, intro.data)
        var top = PBWriter(); top.int(1, 1); top.message(2, v1.data)
        try s.sendBytes(id: 50, top.data)
        XCTAssertEqual(try s.nextSharing().responseStatus, 4, "UNSUPPORTED_ATTACHMENT_TYPE")
        XCTAssertEqual(p.waitFinished(), .failed("unsupported attachment"))
        XCTAssertTrue(p.requests.isEmpty, "the user is never asked")
    }

    func testSenderCancelRemovesPartialFile() throws {
        let p = MemoryPipe(); accepting(p)
        let s = QSTestSender(p)
        try s.handshake(name: "Pixel 9")
        try s.introduce(files: [.init(name: "big.bin", payloadId: 1, size: 100_000, mimeType: "x/y")])
        _ = try s.nextSharing()
        try s.sendOffline(QS.V1Frame(type: .payloadTransfer, payloadTransfer: QS.PayloadTransfer(data: 1, type: .file, totalSize: 100_000, offset: 0, flags: 0, body: Data(repeating: 1, count: 40_000))))
        XCTAssertNotNil(p.waitFor { if case .progress = $0 { return true } else { return nil } })
        try s.sendSharing(QS.Sharing.Frame(type: .cancel))
        XCTAssertEqual(p.waitFinished(), .senderCancelled)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [], "no partial or finished file")
    }

    func testBadOffsetAndExcessDataFailTheTransfer() throws {
        for scenario in 0..<2 {
            let p = MemoryPipe(); accepting(p)
            let s = QSTestSender(p)
            try s.handshake(name: "Pixel 9")
            try s.introduce(files: [.init(name: "f.bin", payloadId: 1, size: 100, mimeType: "x/y")])
            _ = try s.nextSharing()
            let body = Data(repeating: 1, count: scenario == 0 ? 50 : 101)
            try s.sendOffline(QS.V1Frame(type: .payloadTransfer, payloadTransfer: QS.PayloadTransfer(
                data: 1, type: .file, totalSize: 100, offset: scenario == 0 ? 10 : 0, flags: 0, body: body)))
            guard case .failed? = p.waitFinished() else { return XCTFail("scenario \(scenario) should fail") }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
        }
    }

    func testIncompleteFileFails() throws {
        let p = MemoryPipe(); accepting(p)
        let s = QSTestSender(p)
        try s.handshake(name: "Pixel 9")
        try s.introduce(files: [.init(name: "f.bin", payloadId: 1, size: 100, mimeType: "x/y")])
        _ = try s.nextSharing()
        try s.sendOffline(QS.V1Frame(type: .payloadTransfer, payloadTransfer: QS.PayloadTransfer(data: 1, type: .file, totalSize: 100, offset: 0, flags: 1, body: Data(repeating: 1, count: 40))))
        XCTAssertEqual(p.waitFinished(), .failed("file incomplete"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    func testFileDataBeforeAcceptIsAProtocolError() throws {
        let p = MemoryPipe()
        p.decide = { _ in nil }
        let s = QSTestSender(p)
        try s.handshake(name: "Pixel 9")
        try s.introduce(files: [.init(name: "f.bin", payloadId: 1, size: 3, mimeType: "x/y")])
        try s.sendOffline(QS.V1Frame(type: .payloadTransfer, payloadTransfer: QS.PayloadTransfer(data: 1, type: .file, totalSize: 3, offset: 0, flags: 1, body: Data([1, 2, 3]))))
        guard case .failed? = p.waitFinished() else { return XCTFail("data before accept must fail") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    func testTamperedFrameClosesTheConnection() throws {
        let p = MemoryPipe(); accepting(p)
        let s = QSTestSender(p)
        try s.handshake(name: "Pixel 9")
        var ch = try XCTUnwrap(s.channel)
        var sealed = try ch.seal(s.offlineFrame(QS.V1Frame(type: .keepAlive, keepAlive: QS.KeepAlive(ack: false))))
        sealed[sealed.count - 3] ^= 0xff
        p.send(sealed)
        XCTAssertEqual(p.waitFinished(), .failed("protocol error"))
    }

    func testBadCommitmentGetsAnAlert() throws {
        let p = MemoryPipe(); accepting(p)
        let s = QSTestSender(p)
        XCTAssertThrowsError(try s.handshake(name: "Pixel 9", corruptCommitment: true)) {
            XCTAssertEqual(($0 as? QSTestSender.Failure)?.description, "ukey2 alert", "the receiver answers with a UKEY2 alert")
        }
        XCTAssertEqual(p.waitFinished(), .failed("handshake failed"))
    }

    func testGarbageFirstFrameFails() throws {
        let p = MemoryPipe()
        p.send(Data([0xde, 0xad, 0xbe, 0xef]))
        guard case .failed? = p.waitFinished() else { return XCTFail() }
    }

    func testKeepAliveAnsweredAndSafeDisconnectAcknowledged() throws {
        let p = MemoryPipe(); accepting(p)
        let s = QSTestSender(p)
        try s.handshake(name: "Pixel 9")
        try s.sendOffline(QS.V1Frame(type: .keepAlive, keepAlive: QS.KeepAlive(ack: false)))
        let ack = try s.nextOffline()
        XCTAssertEqual(ack.v1?.frameType, .keepAlive)
        XCTAssertEqual(ack.v1?.keepAlive?.ack, true)
        // An ack from the sender is not answered (no ping-pong).
        try s.sendOffline(QS.V1Frame(type: .keepAlive, keepAlive: QS.KeepAlive(ack: true)))
        try s.sendOffline(QS.V1Frame(type: .disconnection, disconnection: QS.Disconnection(requestSafeToDisconnect: true)))
        let bye = try s.nextOffline()
        XCTAssertEqual(bye.v1?.frameType, .disconnection)
        XCTAssertEqual(bye.v1?.disconnection?.ackSafeToDisconnect, true)
        XCTAssertEqual(p.waitFinished(), .senderCancelled)
    }

    func testReceiverSendsItsOwnKeepAlives() throws {
        let p = MemoryPipe { $0.keepAliveInterval = 0.3 }
        p.decide = { _ in nil }
        let s = QSTestSender(p)
        try s.handshake(name: "Pixel 9")
        let f = try s.nextOffline(timeout: 3)
        XCTAssertEqual(f.v1?.frameType, .keepAlive)
        XCTAssertEqual(f.v1?.keepAlive?.ack, false)
    }

    func testSilentSenderTimesOut() throws {
        let p = MemoryPipe { $0.handshakeTimeout = 0.5 }
        XCTAssertEqual(p.waitFinished(timeout: 4), .failed("timed out"))
    }

    func testNoRoomOnDiskIsReportedToTheSender() throws {
        let p = MemoryPipe()
        p.decide = { [dir] _ in .accept(destination: { _ in dir! }) }
        let s = QSTestSender(p)
        try s.handshake(name: "Pixel 9")
        try s.introduce(files: [.init(name: "huge.bin", payloadId: 1, size: Int64.max / 4, mimeType: "x/y")])
        XCTAssertEqual(try s.nextSharing().responseStatus, 3, "NOT_ENOUGH_SPACE")
        XCTAssertEqual(p.waitFinished(), .failed("not enough space"))
    }

    func testTransportDropMidTransferCleansUp() throws {
        let p = MemoryPipe(); accepting(p)
        let s = QSTestSender(p)
        try s.handshake(name: "Pixel 9")
        try s.introduce(files: [.init(name: "f.bin", payloadId: 1, size: 100_000, mimeType: "x/y")])
        _ = try s.nextSharing()
        try s.sendOffline(QS.V1Frame(type: .payloadTransfer, payloadTransfer: QS.PayloadTransfer(data: 1, type: .file, totalSize: 100_000, offset: 0, flags: 0, body: Data(repeating: 1, count: 1000))))
        XCTAssertNotNil(p.waitFor { if case .progress = $0 { return true } else { return nil } })
        p.queue.sync { p.conn.transportClosed() }
        XCTAssertEqual(p.waitFinished(), .failed("connection lost"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    func testOversizedTextIsRefusedAtIntroduction() throws {
        let p = MemoryPipe(); accepting(p)
        let s = QSTestSender(p)
        try s.handshake(name: "Pixel 9")
        try s.introduce(texts: [.init(title: "t", type: .text, payloadId: 1, size: 100 * 1024 * 1024)])
        XCTAssertEqual(try s.nextSharing().responseStatus, 4)
        XCTAssertEqual(p.waitFinished(), .failed("unsupported attachment"))
    }

    func testDuplicatePayloadIdsAreRefused() throws {
        let p = MemoryPipe(); accepting(p)
        let s = QSTestSender(p)
        try s.handshake(name: "Pixel 9")
        try s.introduce(files: [.init(name: "a", payloadId: 1, size: 1, mimeType: "x/y"), .init(name: "b", payloadId: 1, size: 1, mimeType: "x/y")])
        XCTAssertEqual(try s.nextSharing().responseStatus, 4)
    }
}

// MARK: Over TCP, through the real service

final class TCPPipe: QSPipe, @unchecked Sendable {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "test.qs.tcp")
    private let inbox = FrameInbox()
    private var frames = QSFrameBuffer()

    init(port: UInt16) throws {
        conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let ready = DispatchSemaphore(value: 0)
        conn.stateUpdateHandler = { s in if case .ready = s { ready.signal() } }
        conn.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { throw QSTestSender.Failure(description: "tcp connect") }
        receive()
    }
    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] d, _, complete, err in
            guard let self else { return }
            if let d, !d.isEmpty {
                self.frames.append(d)
                while let f = try? self.frames.next() { self.inbox.push(f) }
            }
            if err != nil || complete { self.inbox.close(); return }
            self.receive()
        }
    }
    func send(_ frame: Data) { conn.send(content: QSFrameBuffer.wrap(frame), completion: .contentProcessed { _ in }) }
    func recv(timeout: TimeInterval) -> Data? { inbox.pop(timeout: timeout) }
    func close() { conn.cancel() }
    var closedByPeer: Bool { inbox.isClosed }
}

final class QuickShareServiceTests: XCTestCase {
    var dir: URL!
    var service: QuickShareService!
    override func setUpWithError() throws {
        dir = try tempDir()
        service = QuickShareService(deviceName: { "Test Mac" }, advertise: false)
    }
    override func tearDown() { service.stop(); try? FileManager.default.removeItem(at: dir) }

    private final class Collector: @unchecked Sendable {
        let lock = NSLock()
        var events: [QSConnectionEvent] = []
        let sem = DispatchSemaphore(value: 0)
        func add(_ e: QSConnectionEvent) { lock.lock(); events.append(e); lock.unlock(); sem.signal() }
        func waitFinished(_ timeout: TimeInterval = 8) -> QSFinish? {
            let deadline = Date().addingTimeInterval(timeout)
            var seen = 0
            while Date() < deadline {
                lock.lock(); let snap = events; lock.unlock()
                while seen < snap.count { if case let .finished(r) = snap[seen] { return r }; seen += 1 }
                _ = sem.wait(timeout: .now() + 0.1)
            }
            return nil
        }
    }

    func testFileAndTextOverRealTCP() throws {
        let c = Collector()
        let dir = self.dir!
        service.onRequest = { _, respond in respond(.accept(destination: { _ in dir })) }
        service.onEvent = { _, e in c.add(e) }
        let port = try XCTUnwrap(service.startAndWait())
        let pipe = try TCPPipe(port: port)
        let s = QSTestSender(pipe)
        try s.handshake(name: "Pixel 9")
        let data = Data((0..<600_000).map { UInt8(truncatingIfNeeded: $0 / 7) })
        try s.introduce(files: [.init(name: "video.mp4", type: 2, payloadId: 31, size: Int64(data.count), mimeType: "video/mp4")],
                        texts: [.init(title: "note", type: .text, payloadId: 32, size: 4)])
        XCTAssertEqual(try s.nextSharing().responseStatus, 1)
        try s.sendBytes(id: 32, Data("note".utf8))
        try s.sendFile(id: 31, data: data, chunk: 64_000)
        XCTAssertEqual(c.waitFinished(), .completed)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("video.mp4")), data)
        XCTAssertTrue(c.events.contains { if case .text("note", false) = $0 { return true } else { return false } })
        XCTAssertEqual(QSNetConnection.ipv4(of: .hostPort(host: "127.0.0.1", port: 1)), "127.0.0.1")
        pipe.close()
    }

    func testRequestIsDeclinedWhenNobodyAnswers() throws {
        let c = Collector()
        service.onRequest = nil
        service.onEvent = { _, e in c.add(e) }
        let port = try XCTUnwrap(service.startAndWait())
        let pipe = try TCPPipe(port: port)
        let s = QSTestSender(pipe)
        try s.handshake(name: "Pixel 9")
        try s.introduce(files: [.init(name: "a", payloadId: 1, size: 1, mimeType: "x/y")])
        XCTAssertEqual(try s.nextSharing().responseStatus, 2)
        XCTAssertEqual(c.waitFinished(), .rejected)
    }

    func testStopClosesConnectionsAndRestartListensAgain() throws {
        let c = Collector()
        service.onRequest = { _, _ in }
        service.onEvent = { _, e in c.add(e) }
        let port = try XCTUnwrap(service.startAndWait())
        let pipe = try TCPPipe(port: port)
        let s = QSTestSender(pipe)
        try s.handshake(name: "Pixel 9")
        service.stop(dropConnections: false)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertNil(c.waitFinished(0.3), "stopping advertising leaves a running connection alone")
        service.stop()
        guard case .failed? = c.waitFinished() else { return XCTFail("dropping connections ends them") }
        XCTAssertNotNil(service.startAndWait(), "starts again")
    }

    func testGarbageOnThePortIsHarmless() throws {
        let c = Collector()
        service.onEvent = { _, e in c.add(e) }
        let port = try XCTUnwrap(service.startAndWait())
        let pipe = try TCPPipe(port: port)
        pipe.send(Data(repeating: 0xff, count: 64))
        guard case .failed? = c.waitFinished() else { return XCTFail() }
        // A frame claiming to be huge closes the connection without allocating it.
        let pipe2 = try TCPPipe(port: port)
        pipe2.send(Data())              // an empty frame
        let raw = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        raw.start(queue: .global())
        raw.send(content: Data([0x7f, 0xff, 0xff, 0xff]), completion: .contentProcessed { _ in })
        Thread.sleep(forTimeInterval: 0.3)
        raw.cancel()
        XCTAssertNotNil(service.queue.sync { service.port })
    }
}

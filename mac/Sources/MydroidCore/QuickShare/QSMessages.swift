import Foundation

/// The Quick Share (Nearby Share) messages Mydroid needs to receive files, text and links, hand-coded over `PBWriter` and
/// `PBMessage`. Field numbers and enum values follow the protobuf definitions collected in NearDrop's `ProtobufSource`
/// (Unlicense, public domain): https://github.com/grishka/NearDrop. Only the fields Mydroid reads or writes are modelled.
enum QS {
    // MARK: Nearby Connections: offline frames (plaintext, and the inside of secure messages)

    struct OfflineFrame: Equatable {
        var v1: V1Frame?

        func encode() -> Data {
            var w = PBWriter()
            w.int(1, 1)                        // version V1
            if let v1 { w.message(2, v1.encode()) }
            return w.data
        }
        init(v1: V1Frame?) { self.v1 = v1 }
        init(_ data: Data) throws {
            let m = try PBMessage(data)
            v1 = try m.message(2).map(V1Frame.init)
        }
    }

    struct V1Frame: Equatable {
        enum FrameType: Int64 {
            case unknown = 0, connectionRequest = 1, connectionResponse = 2, payloadTransfer = 3, bandwidthUpgrade = 4
            case keepAlive = 5, disconnection = 6, pairedKeyEncryption = 7
        }
        var type: Int64?
        var connectionRequest: ConnectionRequest?
        var connectionResponse: ConnectionResponse?
        var payloadTransfer: PayloadTransfer?
        var keepAlive: KeepAlive?
        var disconnection: Disconnection?

        var frameType: FrameType? { type.flatMap(FrameType.init(rawValue:)) }

        init(type: FrameType, connectionRequest: ConnectionRequest? = nil, connectionResponse: ConnectionResponse? = nil,
             payloadTransfer: PayloadTransfer? = nil, keepAlive: KeepAlive? = nil, disconnection: Disconnection? = nil) {
            self.type = type.rawValue
            self.connectionRequest = connectionRequest; self.connectionResponse = connectionResponse
            self.payloadTransfer = payloadTransfer; self.keepAlive = keepAlive; self.disconnection = disconnection
        }

        func encode() -> Data {
            var w = PBWriter()
            if let type { w.int(1, type) }
            if let connectionRequest { w.message(2, connectionRequest.encode()) }
            if let connectionResponse { w.message(3, connectionResponse.encode()) }
            if let payloadTransfer { w.message(4, payloadTransfer.encode()) }
            if let keepAlive { w.message(6, keepAlive.encode()) }
            if let disconnection { w.message(7, disconnection.encode()) }
            return w.data
        }
        init(_ m: PBMessage) throws {
            type = m.int64(1)
            connectionRequest = try m.message(2).map(ConnectionRequest.init)
            connectionResponse = try m.message(3).map(ConnectionResponse.init)
            payloadTransfer = try m.message(4).map(PayloadTransfer.init)
            keepAlive = try m.message(6).map(KeepAlive.init)
            disconnection = try m.message(7).map(Disconnection.init)
        }
    }

    struct ConnectionRequest: Equatable {
        var endpointId: String?
        var endpointName: String?
        var endpointInfo: Data?
        var mediums: [Int64] = []
        var keepAliveIntervalMillis: Int32?

        init(endpointId: String? = nil, endpointName: String? = nil, endpointInfo: Data? = nil, mediums: [Int64] = [], keepAliveIntervalMillis: Int32? = nil) {
            self.endpointId = endpointId; self.endpointName = endpointName; self.endpointInfo = endpointInfo
            self.mediums = mediums; self.keepAliveIntervalMillis = keepAliveIntervalMillis
        }
        func encode() -> Data {
            var w = PBWriter()
            if let endpointId { w.string(1, endpointId) }
            if let endpointName { w.string(2, endpointName) }
            if let endpointInfo { w.bytes(6, endpointInfo) }
            for m in mediums { w.int(5, m) }
            if let keepAliveIntervalMillis { w.int(8, Int64(keepAliveIntervalMillis)) }
            return w.data
        }
        init(_ m: PBMessage) throws {
            endpointId = m.string(1)
            endpointName = m.string(2)
            endpointInfo = m.bytes(6)
            mediums = try m.varints(5).map { Int64(bitPattern: $0) }
            keepAliveIntervalMillis = m.int32(8)
        }
    }

    struct ConnectionResponse: Equatable {
        enum Response: Int64 { case unknown = 0, accept = 1, reject = 2 }
        enum OsType: Int64 { case unknown = 0, android = 1, chromeOS = 2, windows = 3, apple = 4, linux = 100 }
        var status: Int32?
        var response: Int64?
        var osType: Int64?

        init(status: Int32? = 0, response: Response, osType: OsType? = nil) {
            self.status = status; self.response = response.rawValue; self.osType = osType?.rawValue
        }
        func encode() -> Data {
            var w = PBWriter()
            if let status { w.int(1, Int64(status)) }
            if let response { w.int(3, response) }
            if let osType {
                var o = PBWriter(); o.int(1, osType)
                w.message(4, o.data)
            }
            return w.data
        }
        init(_ m: PBMessage) throws {
            status = m.int32(1)
            response = m.int64(3)
            osType = try m.message(4)?.int64(1)
        }
    }

    struct PayloadTransfer: Equatable {
        enum PacketType: Int64 { case unknown = 0, data = 1, control = 2, payloadAck = 3 }
        enum PayloadType: Int64 { case unknown = 0, bytes = 1, file = 2, stream = 3 }
        enum ControlEvent: Int64 { case unknown = 0, error = 1, canceled = 2, receivedAck = 3 }

        var packetType: Int64?
        var payloadId: Int64?
        var payloadType: Int64?
        var totalSize: Int64?
        var fileName: String?
        var chunkFlags: Int32?
        var chunkOffset: Int64?
        var chunkBody: Data?
        var controlEvent: Int64?

        static let lastChunk: Int32 = 1

        init(data id: Int64, type: PayloadType, totalSize: Int64, offset: Int64, flags: Int32, body: Data?, fileName: String? = nil) {
            packetType = PacketType.data.rawValue
            payloadId = id; payloadType = type.rawValue; self.totalSize = totalSize; self.fileName = fileName
            chunkFlags = flags; chunkOffset = offset; chunkBody = body
        }

        func encode() -> Data {
            var w = PBWriter()
            if let packetType { w.int(1, packetType) }
            if payloadId != nil || payloadType != nil || totalSize != nil || fileName != nil {
                var h = PBWriter()
                if let payloadId { h.int(1, payloadId) }
                if let payloadType { h.int(2, payloadType) }
                if let totalSize { h.int(3, totalSize) }
                h.bool(4, false)
                if let fileName { h.string(5, fileName) }
                w.message(2, h.data)
            }
            if chunkFlags != nil || chunkOffset != nil || chunkBody != nil {
                var c = PBWriter()
                if let chunkFlags { c.int(1, Int64(chunkFlags)) }
                if let chunkOffset { c.int(2, chunkOffset) }
                if let chunkBody { c.bytes(3, chunkBody) }
                w.message(3, c.data)
            }
            if let controlEvent {
                var c = PBWriter(); c.int(1, controlEvent)
                w.message(4, c.data)
            }
            return w.data
        }
        init(_ m: PBMessage) throws {
            packetType = m.int64(1)
            if let h = try m.message(2) {
                payloadId = h.int64(1); payloadType = h.int64(2); totalSize = h.int64(3); fileName = h.string(5)
            }
            if let c = try m.message(3) {
                chunkFlags = c.int32(1); chunkOffset = c.int64(2); chunkBody = c.bytes(3)
            }
            if let c = try m.message(4) { controlEvent = c.int64(1) }
        }
        var isLast: Bool { (chunkFlags ?? 0) & Self.lastChunk != 0 }
    }

    struct KeepAlive: Equatable {
        var ack: Bool?
        init(ack: Bool?) { self.ack = ack }
        func encode() -> Data { var w = PBWriter(); if let ack { w.bool(1, ack) }; return w.data }
        init(_ m: PBMessage) throws { ack = m.bool(1) }
    }

    struct Disconnection: Equatable {
        var requestSafeToDisconnect: Bool?
        var ackSafeToDisconnect: Bool?
        init(requestSafeToDisconnect: Bool? = nil, ackSafeToDisconnect: Bool? = nil) {
            self.requestSafeToDisconnect = requestSafeToDisconnect; self.ackSafeToDisconnect = ackSafeToDisconnect
        }
        func encode() -> Data {
            var w = PBWriter()
            if let requestSafeToDisconnect { w.bool(1, requestSafeToDisconnect) }
            if let ackSafeToDisconnect { w.bool(2, ackSafeToDisconnect) }
            return w.data
        }
        init(_ m: PBMessage) throws { requestSafeToDisconnect = m.bool(1); ackSafeToDisconnect = m.bool(2) }
    }

    // MARK: UKEY2 (google/ukey2) and SecureMessage (google/securemessage)

    enum Ukey2 {
        enum MessageType: Int64 { case unknown = 0, alert = 1, clientInit = 2, serverInit = 3, clientFinish = 4 }
        enum AlertType: Int64 {
            case badMessage = 1, badMessageType = 2, incorrectMessage = 3, badMessageData = 4
            case badVersion = 100, badRandom = 101, badHandshakeCipher = 102, badNextProtocol = 103, badPublicKey = 104
            case internalError = 200
        }
        static let handshakeCipherP256Sha512: Int64 = 100
        static let nextProtocol = "AES_256_CBC-HMAC_SHA256"

        struct Message: Equatable {
            var type: Int64?
            var data: Data?
            init(type: MessageType, data: Data) { self.type = type.rawValue; self.data = data }
            func encode() -> Data {
                var w = PBWriter()
                if let type { w.int(1, type) }
                if let data { w.bytes(2, data) }
                return w.data
            }
            init(_ d: Data) throws { let m = try PBMessage(d); type = m.int64(1); data = m.bytes(2) }
        }

        struct Alert: Equatable {
            var type: AlertType
            var message: String?
            func encode() -> Data {
                var w = PBWriter()
                w.int(1, type.rawValue)
                if let message { w.string(2, message) }
                return w.data
            }
        }

        struct ClientInit: Equatable {
            struct Commitment: Equatable { var cipher: Int64; var commitment: Data }
            var version: Int32?
            var random: Data?
            var commitments: [Commitment] = []
            var nextProtocol: String?

            init(version: Int32?, random: Data?, commitments: [Commitment], nextProtocol: String?) {
                self.version = version; self.random = random; self.commitments = commitments; self.nextProtocol = nextProtocol
            }
            func encode() -> Data {
                var w = PBWriter()
                if let version { w.int(1, Int64(version)) }
                if let random { w.bytes(2, random) }
                for c in commitments {
                    var cw = PBWriter(); cw.int(1, c.cipher); cw.bytes(2, c.commitment)
                    w.message(3, cw.data)
                }
                if let nextProtocol { w.string(4, nextProtocol) }
                return w.data
            }
            init(_ d: Data) throws {
                let m = try PBMessage(d)
                version = m.int32(1); random = m.bytes(2)
                commitments = try m.messages(3).map { Commitment(cipher: $0.int64(1) ?? 0, commitment: $0.bytes(2) ?? Data()) }
                nextProtocol = m.string(4)
            }
        }

        struct ServerInit: Equatable {
            var version: Int32?
            var random: Data?
            var handshakeCipher: Int64?
            var publicKey: Data?
            init(version: Int32?, random: Data?, handshakeCipher: Int64?, publicKey: Data?) {
                self.version = version; self.random = random; self.handshakeCipher = handshakeCipher; self.publicKey = publicKey
            }
            func encode() -> Data {
                var w = PBWriter()
                if let version { w.int(1, Int64(version)) }
                if let random { w.bytes(2, random) }
                if let handshakeCipher { w.int(3, handshakeCipher) }
                if let publicKey { w.bytes(4, publicKey) }
                return w.data
            }
            init(_ d: Data) throws {
                let m = try PBMessage(d)
                version = m.int32(1); random = m.bytes(2); handshakeCipher = m.int64(3); publicKey = m.bytes(4)
            }
        }

        struct ClientFinished: Equatable {
            var publicKey: Data?
            init(publicKey: Data?) { self.publicKey = publicKey }
            func encode() -> Data { var w = PBWriter(); if let publicKey { w.bytes(1, publicKey) }; return w.data }
            init(_ d: Data) throws { publicKey = try PBMessage(d).bytes(1) }
        }
    }

    enum Secure {
        static let hmacSha256: Int64 = 1
        static let aes256Cbc: Int64 = 2
        static let deviceToDeviceMessageType: Int64 = 13    // securegcm GcmMetadata.Type DEVICE_TO_DEVICE_MESSAGE

        struct Message: Equatable {
            var headerAndBody: Data?
            var signature: Data?
            init(headerAndBody: Data, signature: Data) { self.headerAndBody = headerAndBody; self.signature = signature }
            func encode() -> Data {
                var w = PBWriter()
                if let headerAndBody { w.bytes(1, headerAndBody) }
                if let signature { w.bytes(2, signature) }
                return w.data
            }
            init(_ d: Data) throws { let m = try PBMessage(d); headerAndBody = m.bytes(1); signature = m.bytes(2) }
        }

        struct HeaderAndBody: Equatable {
            var signatureScheme: Int64?
            var encryptionScheme: Int64?
            var iv: Data?
            var publicMetadata: Data?
            var body: Data?
            init(iv: Data, publicMetadata: Data, body: Data) {
                signatureScheme = hmacSha256; encryptionScheme = aes256Cbc
                self.iv = iv; self.publicMetadata = publicMetadata; self.body = body
            }
            func encode() -> Data {
                var h = PBWriter()
                if let signatureScheme { h.int(1, signatureScheme) }
                if let encryptionScheme { h.int(2, encryptionScheme) }
                if let iv { h.bytes(5, iv) }
                if let publicMetadata { h.bytes(6, publicMetadata) }
                var w = PBWriter()
                w.message(1, h.data)
                if let body { w.bytes(2, body) }
                return w.data
            }
            init(_ d: Data) throws {
                let m = try PBMessage(d)
                if let h = try m.message(1) {
                    signatureScheme = h.int64(1); encryptionScheme = h.int64(2); iv = h.bytes(5); publicMetadata = h.bytes(6)
                }
                body = m.bytes(2)
            }
        }

        /// securegcm GcmMetadata: `type` DEVICE_TO_DEVICE_MESSAGE, `version` 1.
        static func gcmMetadata() -> Data {
            var w = PBWriter(); w.int(1, deviceToDeviceMessageType); w.int(2, 1); return w.data
        }

        /// securegcm DeviceToDeviceMessage.
        struct DeviceToDevice: Equatable {
            var message: Data?
            var sequenceNumber: Int32?
            init(message: Data, sequenceNumber: Int32) { self.message = message; self.sequenceNumber = sequenceNumber }
            func encode() -> Data {
                var w = PBWriter()
                if let message { w.bytes(1, message) }
                if let sequenceNumber { w.int(2, Int64(sequenceNumber)) }
                return w.data
            }
            init(_ d: Data) throws { let m = try PBMessage(d); message = m.bytes(1); sequenceNumber = m.int32(2) }
        }

        /// securemessage GenericPublicKey carrying an EC P-256 point. `x` and `y` are big-endian signed integers (Java BigInteger style).
        struct PublicKey: Equatable {
            var x: Data
            var y: Data
            func encode() -> Data {
                var p = PBWriter(); p.bytes(1, x); p.bytes(2, y)
                var w = PBWriter()
                w.int(1, 1)                    // EC_P256
                w.message(2, p.data)
                return w.data
            }
            init(x: Data, y: Data) { self.x = x; self.y = y }
            init(_ d: Data) throws {
                let m = try PBMessage(d)
                guard m.int64(1) == 1, let p = try m.message(2), let x = p.bytes(1), let y = p.bytes(2) else { throw PBError.truncated }
                self.x = x; self.y = y
            }
        }
    }

    // MARK: Nearby Share (the layer on top, carried in BYTES payloads)

    enum Sharing {
        struct Frame: Equatable {
            enum FrameType: Int64 { case unknown = 0, introduction = 1, response = 2, pairedKeyEncryption = 3, pairedKeyResult = 4, certificateInfo = 5, cancel = 6, progressUpdate = 7 }
            var type: Int64?
            var introduction: Introduction?
            var responseStatus: Int64?
            var pairedKeyEncryption: PairedKeyEncryption?
            var pairedKeyResultStatus: Int64?

            var frameType: FrameType? { type.flatMap(FrameType.init(rawValue:)) }

            init(type: FrameType, introduction: Introduction? = nil, responseStatus: ResponseStatus? = nil,
                 pairedKeyEncryption: PairedKeyEncryption? = nil, pairedKeyResultStatus: Int64? = nil) {
                self.type = type.rawValue; self.introduction = introduction; self.responseStatus = responseStatus?.rawValue
                self.pairedKeyEncryption = pairedKeyEncryption; self.pairedKeyResultStatus = pairedKeyResultStatus
            }

            func encode() -> Data {
                var v1 = PBWriter()
                if let type { v1.int(1, type) }
                if let introduction { v1.message(2, introduction.encode()) }
                if let responseStatus { var r = PBWriter(); r.int(1, responseStatus); v1.message(3, r.data) }
                if let pairedKeyEncryption { v1.message(4, pairedKeyEncryption.encode()) }
                if let pairedKeyResultStatus { var r = PBWriter(); r.int(1, pairedKeyResultStatus); v1.message(5, r.data) }
                var w = PBWriter()
                w.int(1, 1)                    // version V1
                w.message(2, v1.data)
                return w.data
            }
            init(_ d: Data) throws {
                let m = try PBMessage(d)
                guard let v1 = try m.message(2) else { return }
                type = v1.int64(1)
                introduction = try v1.message(2).map(Introduction.init)
                responseStatus = try v1.message(3)?.int64(1)
                pairedKeyEncryption = try v1.message(4).map(PairedKeyEncryption.init)
                pairedKeyResultStatus = try v1.message(5)?.int64(1)
            }
        }

        enum ResponseStatus: Int64 { case unknown = 0, accept = 1, reject = 2, notEnoughSpace = 3, unsupportedAttachmentType = 4, timedOut = 5 }
        static let pairedKeyResultUnable: Int64 = 3

        struct PairedKeyEncryption: Equatable {
            var signedData: Data?
            var secretIdHash: Data?
            init(signedData: Data?, secretIdHash: Data?) { self.signedData = signedData; self.secretIdHash = secretIdHash }
            func encode() -> Data {
                var w = PBWriter()
                if let signedData { w.bytes(1, signedData) }
                if let secretIdHash { w.bytes(2, secretIdHash) }
                return w.data
            }
            init(_ m: PBMessage) throws { signedData = m.bytes(1); secretIdHash = m.bytes(2) }
        }

        struct FileMetadata: Equatable {
            var name: String?
            var type: Int64?
            var payloadId: Int64?
            var size: Int64?
            var mimeType: String?
            init(name: String, type: Int64 = 0, payloadId: Int64, size: Int64, mimeType: String) {
                self.name = name; self.type = type; self.payloadId = payloadId; self.size = size; self.mimeType = mimeType
            }
            func encode() -> Data {
                var w = PBWriter()
                if let name { w.string(1, name) }
                if let type { w.int(2, type) }
                if let payloadId { w.int(3, payloadId) }
                if let size { w.int(4, size) }
                if let mimeType { w.string(5, mimeType) }
                return w.data
            }
            init(_ m: PBMessage) throws {
                name = m.string(1); type = m.int64(2); payloadId = m.int64(3); size = m.int64(4); mimeType = m.string(5)
            }
        }

        struct TextMetadata: Equatable {
            enum TextType: Int64 { case unknown = 0, text = 1, url = 2, address = 3, phoneNumber = 4 }
            var title: String?
            var type: Int64?
            var payloadId: Int64?
            var size: Int64?
            init(title: String?, type: TextType, payloadId: Int64, size: Int64) {
                self.title = title; self.type = type.rawValue; self.payloadId = payloadId; self.size = size
            }
            func encode() -> Data {
                var w = PBWriter()
                if let title { w.string(2, title) }
                if let type { w.int(3, type) }
                if let payloadId { w.int(4, payloadId) }
                if let size { w.int(5, size) }
                return w.data
            }
            init(_ m: PBMessage) throws {
                title = m.string(2); type = m.int64(3); payloadId = m.int64(4); size = m.int64(5)
            }
            var textType: TextType { type.flatMap(TextType.init(rawValue:)) ?? .unknown }
        }

        struct Introduction: Equatable {
            var files: [FileMetadata] = []
            var texts: [TextMetadata] = []
            /// Wi-Fi credentials, apps and streams: Mydroid doesn't accept these.
            var otherAttachments = 0

            init(files: [FileMetadata] = [], texts: [TextMetadata] = [], otherAttachments: Int = 0) {
                self.files = files; self.texts = texts; self.otherAttachments = otherAttachments
            }
            func encode() -> Data {
                var w = PBWriter()
                for f in files { w.message(1, f.encode()) }
                for t in texts { w.message(2, t.encode()) }
                return w.data
            }
            init(_ m: PBMessage) throws {
                files = try m.messages(1).map(FileMetadata.init)
                texts = try m.messages(2).map(TextMetadata.init)
                // wifi_credentials_metadata (4), app_metadata (5), stream_metadata (7)
                otherAttachments = m.fields.filter { ($0.number == 4 || $0.number == 5 || $0.number == 7) && $0.wire == 2 }.count
            }
        }
    }
}

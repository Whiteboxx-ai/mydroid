import Foundation

// The receiving side of one Quick Share connection: Nearby Connections handshake, UKEY2, the secure message layer and the
// Nearby Share exchange (introduction, accept, payloads). Follows the flow described in NearDrop's PROTOCOL.md and implemented
// in its InboundNearbyConnection.swift (Unlicense, public domain): https://github.com/grishka/NearDrop
//
// Nothing here touches the network: frames come in through `receive(_:)` and go out through `sendFrame`, so the whole state
// machine can be driven in memory by tests. All calls must be made on `queue`.

public struct QSItem: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable { case file, text, url }
    /// The payload id.
    public var id: Int64
    public var kind: Kind
    /// A safe file name for files; the title for text.
    public var name: String
    public var size: Int64
    public var mime: String
}

public struct QSRequest: Sendable, Equatable {
    public var id: String
    public var senderName: String
    public var deviceType: QSDeviceType
    public var remoteHost: String?
    /// The 4-digit PIN both devices show.
    public var pin: String
    public var items: [QSItem]

    public var files: [QSItem] { items.filter { $0.kind == .file } }
    public var totalFileBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

public enum QSDecision {
    /// `destination` gives the folder each file is saved into.
    case accept(destination: (QSItem) -> URL)
    case reject
}

public enum QSFinish: Sendable, Equatable {
    case completed
    case rejected
    case timedOut
    case senderCancelled
    /// A short reason with no file names or content in it.
    case failed(String)
}

public enum QSConnectionEvent: Sendable {
    /// The request is no longer waiting for an answer (answered, timed out, cancelled by the sender or the link dropped).
    case decisionEnded
    case progress(item: QSItem, written: Int64)
    case file(item: QSItem, url: URL)
    case text(String, isURL: Bool)
    case finished(QSFinish)
}

protocol QSConnectionDelegate: AnyObject {
    /// Called once the sender's introduction is known. Call `respond` (any thread) with the user's, or the policy's, answer.
    func qsConnection(_ id: String, request: QSRequest, respond: @escaping (QSDecision) -> Void)
    func qsConnection(_ id: String, event: QSConnectionEvent)
}

final class QSInboundConnection {
    enum Phase: Equatable {
        case awaitConnectionRequest, awaitClientInit, awaitClientFinish, awaitConnectionResponse
        case secure, awaitingDecision, receiving, finished
    }

    static let maxFrameLength = 5 * 1024 * 1024
    static let maxBytesPayload = 4 * 1024 * 1024
    static let maxItems = 100

    let id: String
    let remoteHost: String?
    weak var delegate: QSConnectionDelegate?
    var log: (String) -> Void = { _ in }
    var decisionTimeout: TimeInterval = 30
    var handshakeTimeout: TimeInterval = 20
    var idleTimeout: TimeInterval = 45
    var keepAliveInterval: TimeInterval = 10

    private let queue: DispatchQueue
    private let sendFrame: (Data) -> Void
    private let closeTransport: () -> Void
    private(set) var phase: Phase = .awaitConnectionRequest

    private let handshake = QSServerHandshake()
    private var channel: QSSecureChannel?
    private var pin = ""
    private var senderName = "Unknown device"
    private var deviceType: QSDeviceType = .unknown
    private var pairedKeyResultSent = false
    private var request: QSRequest?
    private var decisionPending = false
    private var decisionTimer: DispatchWorkItem?
    private var ticker: DispatchSourceTimer?
    private var lastActivity = Date()
    private var lastKeepAlive = Date()
    private let startedAt = Date()

    private var buffers: [Int64: Data] = [:]
    private var textItems: [Int64: QSItem] = [:]
    private var files: [Int64: IncomingFile] = [:]
    private var outgoingPayloadId: Int64 = Int64.random(in: 1...Int64.max)

    private final class IncomingFile {
        let item: QSItem
        let dir: URL
        let part: URL
        let handle: FileHandle
        var written: Int64 = 0
        init(item: QSItem, dir: URL, part: URL, handle: FileHandle) { self.item = item; self.dir = dir; self.part = part; self.handle = handle }
    }

    init(id: String, remoteHost: String?, queue: DispatchQueue, sendFrame: @escaping (Data) -> Void, closeTransport: @escaping () -> Void) {
        self.id = id; self.remoteHost = remoteHost; self.queue = queue
        self.sendFrame = sendFrame; self.closeTransport = closeTransport
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        ticker = t
    }

    var isFinished: Bool { phase == .finished }

    // MARK: Timers

    private func tick() {
        guard phase != .finished else { return }
        let now = Date()
        let limit = (phase == .secure || phase == .awaitingDecision || phase == .receiving) ? idleTimeout : handshakeTimeout
        // While the user decides, the sender's keep-alives arrive every 10 seconds, so a silent sender is a gone sender.
        if now.timeIntervalSince(lastActivity) > limit { return fail("timed out") }
        if phase == .secure || phase == .awaitingDecision || phase == .receiving, now.timeIntervalSince(lastKeepAlive) >= keepAliveInterval {
            lastKeepAlive = now
            try? sendEncrypted(QS.OfflineFrame(v1: QS.V1Frame(type: .keepAlive, keepAlive: QS.KeepAlive(ack: false))))
        }
    }

    // MARK: Input

    func receive(_ frame: Data) {
        guard phase != .finished else { return }
        lastActivity = Date()
        do {
            switch phase {
            case .awaitConnectionRequest: try handleConnectionRequest(frame)
            case .awaitClientInit: try handleClientInit(frame)
            case .awaitClientFinish: try handleClientFinish(frame)
            case .awaitConnectionResponse: try handleClientConnectionResponse(frame)
            case .secure, .awaitingDecision, .receiving: try handleSecure(frame)
            case .finished: break
            }
        } catch let f as QSServerHandshake.Failure {
            if case .alert(let type) = f { sendUkey2Alert(type) }
            fail("handshake failed")
        } catch {
            fail("protocol error")
        }
    }

    /// The transport went away.
    func transportClosed() {
        guard phase != .finished else { return }
        finish(phase == .receiving || phase == .awaitingDecision ? .failed("connection lost") : .failed("connection closed"))
    }

    // MARK: Plaintext phases

    private func handleConnectionRequest(_ frame: Data) throws {
        let offline = try QS.OfflineFrame(frame)
        guard let v1 = offline.v1, v1.frameType == .connectionRequest, let req = v1.connectionRequest else { throw QSCryptoError.badMessage("expected connection request") }
        let info = req.endpointInfo.flatMap(QSEndpoint.parseEndpointInfo)
        senderName = (info?.name).flatMap { $0.isEmpty ? nil : $0 } ?? req.endpointName.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown device"
        deviceType = info?.deviceType ?? .unknown
        phase = .awaitClientInit
    }

    private func handleClientInit(_ frame: Data) throws {
        let serverInit = try handshake.handleClientInit(frame)
        sendFrame(serverInit)
        phase = .awaitClientFinish
    }

    private func handleClientFinish(_ frame: Data) throws {
        let keys = try handshake.handleClientFinish(frame)
        pin = keys.pin
        channel = QSSecureChannel(keys: keys)
        phase = .awaitConnectionResponse
    }

    private func handleClientConnectionResponse(_ frame: Data) throws {
        let offline = try QS.OfflineFrame(frame)
        guard let v1 = offline.v1, v1.frameType == .connectionResponse else { throw QSCryptoError.badMessage("expected connection response") }
        // The sender may refuse the connection; then there is nothing left to do.
        if let r = v1.connectionResponse?.response, r == QS.ConnectionResponse.Response.reject.rawValue { return finish(.failed("sender closed the connection")) }
        let resp = QS.ConnectionResponse(status: 0, response: .accept, osType: .apple)
        sendFrame(QS.OfflineFrame(v1: QS.V1Frame(type: .connectionResponse, connectionResponse: resp)).encode())
        phase = .secure
        lastKeepAlive = Date()
        // "Presumably used for all the phone number stuff": random bytes work, per NearDrop.
        var rnd = Data(count: 78)
        _ = rnd.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 78, $0.baseAddress!) }
        let pke = QS.Sharing.PairedKeyEncryption(signedData: rnd.suffix(72), secretIdHash: rnd.prefix(6))
        try sendSharing(QS.Sharing.Frame(type: .pairedKeyEncryption, pairedKeyEncryption: pke))
    }

    // MARK: Secure phase

    private func handleSecure(_ frame: Data) throws {
        guard var ch = channel else { throw QSCryptoError.badMessage("no keys") }
        let inner: Data
        do { inner = try ch.open(frame) } catch { channel = ch; throw error }
        channel = ch
        let offline = try QS.OfflineFrame(inner)
        guard let v1 = offline.v1 else { return }
        switch v1.frameType {
        case .payloadTransfer:
            if let pt = v1.payloadTransfer { try handlePayload(pt) }
        case .keepAlive:
            if v1.keepAlive?.ack != true { try sendEncrypted(QS.OfflineFrame(v1: QS.V1Frame(type: .keepAlive, keepAlive: QS.KeepAlive(ack: true)))) }
        case .disconnection:
            if v1.disconnection?.requestSafeToDisconnect == true {
                try? sendEncrypted(QS.OfflineFrame(v1: QS.V1Frame(type: .disconnection, disconnection: QS.Disconnection(ackSafeToDisconnect: true))))
            }
            finish(allDone ? .completed : .senderCancelled)
        default:
            log("quickshare: ignoring frame type \(v1.type ?? -1)")
        }
    }

    private var allDone: Bool { phase == .receiving && files.isEmpty && textItems.isEmpty }

    private func handlePayload(_ pt: QS.PayloadTransfer) throws {
        guard let id = pt.payloadId else { throw QSCryptoError.badMessage("payload id") }
        if pt.packetType == QS.PayloadTransfer.PacketType.control.rawValue {
            if pt.controlEvent == QS.PayloadTransfer.ControlEvent.canceled.rawValue || pt.controlEvent == QS.PayloadTransfer.ControlEvent.error.rawValue {
                if files[id] != nil || textItems[id] != nil { return finish(.senderCancelled) }
            }
            return
        }
        guard pt.packetType == QS.PayloadTransfer.PacketType.data.rawValue || pt.packetType == nil else { return }
        switch pt.payloadType {
        case QS.PayloadTransfer.PayloadType.bytes.rawValue:
            try handleBytesPayload(id: id, pt)
        case QS.PayloadTransfer.PayloadType.file.rawValue:
            try handleFileChunk(id: id, pt)
        default:
            throw QSCryptoError.badMessage("payload type")
        }
    }

    private func handleBytesPayload(id: Int64, _ pt: QS.PayloadTransfer) throws {
        var buf = buffers[id] ?? Data()
        guard (pt.chunkOffset ?? 0) == Int64(buf.count) else { throw QSCryptoError.badMessage("chunk offset") }
        if let body = pt.chunkBody { buf.append(body) }
        guard buf.count <= Self.maxBytesPayload else { throw QSCryptoError.badMessage("payload too large") }
        guard pt.isLast else { buffers[id] = buf; return }
        buffers[id] = nil
        if let item = textItems[id] {
            textItems[id] = nil
            guard phase == .receiving else { throw QSCryptoError.badMessage("text before accept") }
            guard let s = String(data: buf, encoding: .utf8) else { return finish(.failed("text wasn't UTF-8")) }
            delegate?.qsConnection(self.id, event: .text(s, isURL: item.kind == .url))
            completeIfDone()
        } else {
            try handleSharing(try QS.Sharing.Frame(buf))
        }
    }

    // MARK: Nearby Share layer

    private func handleSharing(_ frame: QS.Sharing.Frame) throws {
        switch frame.frameType {
        case .cancel:
            finish(.senderCancelled)
        case .pairedKeyEncryption:
            if !pairedKeyResultSent {
                pairedKeyResultSent = true
                try sendSharing(QS.Sharing.Frame(type: .pairedKeyResult, pairedKeyResultStatus: QS.Sharing.pairedKeyResultUnable))
            }
        case .introduction:
            guard phase == .secure, let intro = frame.introduction else { throw QSCryptoError.badMessage("unexpected introduction") }
            try handleIntroduction(intro)
        default:
            break
        }
    }

    private func handleIntroduction(_ intro: QS.Sharing.Introduction) throws {
        var items: [QSItem] = []
        for f in intro.files {
            guard let pid = f.payloadId, let size = f.size, size >= 0 else { throw QSCryptoError.badMessage("file metadata") }
            items.append(QSItem(id: pid, kind: .file, name: FileNaming.sanitize(f.name ?? "file"), size: size,
                                mime: f.mimeType ?? "application/octet-stream"))
        }
        for t in intro.texts {
            guard let pid = t.payloadId else { throw QSCryptoError.badMessage("text metadata") }
            items.append(QSItem(id: pid, kind: t.textType == .url ? .url : .text, name: t.title ?? "", size: t.size ?? 0, mime: "text/plain"))
        }
        guard intro.otherAttachments == 0, !items.isEmpty, items.count <= Self.maxItems,
              Set(items.map(\.id)).count == items.count,
              items.allSatisfy({ $0.kind == .file || $0.size <= Int64(Self.maxBytesPayload) })
        else {
            return try rejectAndClose(.unsupportedAttachmentType, finish: .failed("unsupported attachment"))
        }
        let req = QSRequest(id: id, senderName: senderName, deviceType: deviceType, remoteHost: remoteHost, pin: pin, items: items)
        request = req
        phase = .awaitingDecision
        decisionPending = true
        let work = DispatchWorkItem { [weak self] in self?.decisionTimedOut() }
        decisionTimer = work
        queue.asyncAfter(deadline: .now() + decisionTimeout, execute: work)
        delegate?.qsConnection(id, request: req) { [weak self] decision in
            guard let self else { return }
            self.queue.async { self.apply(decision) }
        }
    }

    private func decisionTimedOut() {
        guard phase == .awaitingDecision else { return }
        try? rejectAndClose(.timedOut, finish: .timedOut)
    }

    private func endDecision() {
        decisionTimer?.cancel(); decisionTimer = nil
        if decisionPending { decisionPending = false; delegate?.qsConnection(id, event: .decisionEnded) }
    }

    private func apply(_ decision: QSDecision) {
        guard phase == .awaitingDecision, let req = request else { return }
        endDecision()
        switch decision {
        case .reject:
            try? rejectAndClose(.reject, finish: .rejected)
        case .accept(let destination):
            do {
                try prepareFiles(req, destination)
            } catch let e as PrepareError {
                try? rejectAndClose(e == .noSpace ? .notEnoughSpace : .reject, finish: .failed(e == .noSpace ? "not enough space" : "couldn't create the file"))
                return
            } catch { return fail("couldn't create the file") }
            for item in req.items where item.kind != .file { textItems[item.id] = item }
            phase = .receiving
            do { try sendSharing(QS.Sharing.Frame(type: .response, responseStatus: .accept)) } catch { return fail("send failed") }
            completeIfDone()
        }
    }

    private enum PrepareError: Error { case noSpace, createFailed }

    private func prepareFiles(_ req: QSRequest, _ destination: (QSItem) -> URL) throws {
        let fm = FileManager.default
        var created: [IncomingFile] = []
        do {
            for item in req.files {
                let dir = destination(item)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                if let free = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
                   free < req.totalFileBytes + 16 * 1024 * 1024 {
                    throw PrepareError.noSpace
                }
                let part = FileNaming.uniqueURL(in: dir, name: item.name + ".part")
                guard fm.createFile(atPath: part.path, contents: nil) else { throw PrepareError.createFailed }
                let h = try FileHandle(forWritingTo: part)
                let f = IncomingFile(item: item, dir: dir, part: part, handle: h)
                created.append(f)
            }
        } catch {
            for f in created { try? f.handle.close(); try? fm.removeItem(at: f.part) }
            throw error is PrepareError ? error : PrepareError.createFailed
        }
        for f in created { files[f.item.id] = f }
    }

    private func handleFileChunk(id: Int64, _ pt: QS.PayloadTransfer) throws {
        guard phase == .receiving, let f = files[id] else { throw QSCryptoError.badMessage("unknown file payload") }
        guard (pt.chunkOffset ?? 0) == f.written else { throw QSCryptoError.badMessage("file offset") }
        let body = pt.chunkBody ?? Data()
        guard f.written + Int64(body.count) <= f.item.size else { throw QSCryptoError.badMessage("too much data") }
        if !body.isEmpty {
            do { try f.handle.write(contentsOf: body) } catch { return fail("write failed") }
            f.written += Int64(body.count)
            delegate?.qsConnection(self.id, event: .progress(item: f.item, written: f.written))
        }
        guard pt.isLast else { return }
        guard f.written == f.item.size else { return fail("file incomplete") }
        try? f.handle.synchronize()
        try? f.handle.close()
        let final = FileNaming.uniqueURL(in: f.dir, name: f.item.name)
        do { try FileManager.default.moveItem(at: f.part, to: final) } catch { files[id] = nil; return fail("couldn't save the file") }
        files[id] = nil
        delegate?.qsConnection(self.id, event: .file(item: f.item, url: final))
        completeIfDone()
    }

    private func completeIfDone() {
        guard allDone else { return }
        try? sendEncrypted(QS.OfflineFrame(v1: QS.V1Frame(type: .disconnection, disconnection: QS.Disconnection())))
        finish(.completed)
    }

    // MARK: Output

    private func sendEncrypted(_ frame: QS.OfflineFrame) throws {
        guard var ch = channel else { return }
        let sealed = try ch.seal(frame.encode())
        channel = ch
        sendFrame(sealed)
    }

    /// A Nearby Share frame travels as a BYTES payload: one chunk with the data, then an empty chunk with the last-chunk flag.
    private func sendSharing(_ frame: QS.Sharing.Frame) throws {
        let data = frame.encode()
        outgoingPayloadId = outgoingPayloadId &+ 1
        let first = QS.PayloadTransfer(data: outgoingPayloadId, type: .bytes, totalSize: Int64(data.count), offset: 0, flags: 0, body: data)
        let last = QS.PayloadTransfer(data: outgoingPayloadId, type: .bytes, totalSize: Int64(data.count), offset: Int64(data.count),
                                      flags: QS.PayloadTransfer.lastChunk, body: nil)
        try sendEncrypted(QS.OfflineFrame(v1: QS.V1Frame(type: .payloadTransfer, payloadTransfer: first)))
        try sendEncrypted(QS.OfflineFrame(v1: QS.V1Frame(type: .payloadTransfer, payloadTransfer: last)))
    }

    private func sendUkey2Alert(_ type: QS.Ukey2.AlertType) {
        sendFrame(QS.Ukey2.Message(type: .alert, data: QS.Ukey2.Alert(type: type, message: nil).encode()).encode())
    }

    private func rejectAndClose(_ status: QS.Sharing.ResponseStatus, finish reason: QSFinish) throws {
        endDecision()
        try? sendSharing(QS.Sharing.Frame(type: .response, responseStatus: status))
        try? sendEncrypted(QS.OfflineFrame(v1: QS.V1Frame(type: .disconnection, disconnection: QS.Disconnection())))
        finish(reason)
    }

    private func fail(_ reason: String) { finish(.failed(reason)) }

    private func finish(_ reason: QSFinish) {
        guard phase != .finished else { return }
        endDecision()
        phase = .finished
        ticker?.cancel(); ticker = nil
        for f in files.values {
            try? f.handle.close()
            try? FileManager.default.removeItem(at: f.part)
        }
        files.removeAll(); textItems.removeAll(); buffers.removeAll()
        delegate?.qsConnection(id, event: .finished(reason))
        closeTransport()
    }
}

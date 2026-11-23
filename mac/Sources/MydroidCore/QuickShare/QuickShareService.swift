import Foundation
import Network

/// Settings for the Quick Share receiver.
public enum QuickShareVisibility: String, Codable, Sendable, CaseIterable {
    case always, phoneConnected, off
}

public enum QuickShareOthers: String, Codable, Sendable, CaseIterable {
    case ask, never
}

public struct QuickShareSettings: Codable, Equatable, Sendable {
    /// Whether this Mac shows up in Android's Quick Share sheet.
    public var visibility: QuickShareVisibility = .phoneConnected
    /// What to do with a share from a device that isn't your paired phone.
    public var others: QuickShareOthers = .ask
    /// Save received images in the Photos folder instead of Downloads.
    public var imagesToPhotosFolder = false

    public init(visibility: QuickShareVisibility = .phoneConnected, others: QuickShareOthers = .ask, imagesToPhotosFolder: Bool = false) {
        self.visibility = visibility; self.others = others; self.imagesToPhotosFolder = imagesToPhotosFolder
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        visibility = try c.decodeIfPresent(QuickShareVisibility.self, forKey: .visibility) ?? .phoneConnected
        others = try c.decodeIfPresent(QuickShareOthers.self, forKey: .others) ?? .ask
        imagesToPhotosFolder = try c.decodeIfPresent(Bool.self, forKey: .imagesToPhotosFolder) ?? false
    }
}

/// Decides whether a Quick Share sender is the paired phone, so its shares can be accepted without asking.
public enum QuickShareTrust {
    static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The sender's device name must match the paired phone's name (or model), and that phone must be connected to Mydroid right now.
    /// When both addresses are known they must agree too, which stops another device on the network that copied the name.
    public static func isPairedPhone(senderName: String, senderHost: String?, phoneName: String?, phoneModel: String?,
                                     phoneHost: String?, connected: Bool) -> Bool {
        guard connected else { return false }
        let s = normalize(senderName)
        guard !s.isEmpty else { return false }
        let names = [phoneName, phoneModel].compactMap { $0 }.map(normalize).filter { !$0.isEmpty }
        guard names.contains(s) else { return false }
        if let senderHost, let phoneHost, senderHost != phoneHost { return false }
        return true
    }
}

/// Receives Quick Share transfers: advertises the Mac over mDNS, accepts TCP connections and runs a `QSInboundConnection` for each.
/// Runs on its own serial queue; the callbacks below are invoked on that queue.
public final class QuickShareService: QSConnectionDelegate {
    public let queue: DispatchQueue
    public var log: (String) -> Void = { _ in }
    /// Asked when a sender has described what it wants to send. Call `respond` with the answer, now or later (any thread).
    public var onRequest: ((QSRequest, _ respond: @escaping (QSDecision) -> Void) -> Void)?
    public var onEvent: ((_ connectionId: String, QSConnectionEvent) -> Void)?
    public var onListening: ((UInt16?) -> Void)?

    public private(set) var port: UInt16?
    public var isRunning: Bool { listener != nil }

    private let deviceName: () -> String
    private let advertise: Bool
    private let endpointId = QSEndpoint.randomEndpointId()
    private var listener: NWListener?
    private var generation = 0
    private var connections: [String: QSNetConnection] = [:]
    static let maxConnections = 5

    public init(deviceName: @escaping () -> String, advertise: Bool = true, queue: DispatchQueue = DispatchQueue(label: "com.mydroid.quickshare")) {
        self.deviceName = deviceName; self.advertise = advertise; self.queue = queue
    }

    /// Starts listening (and advertising, unless disabled). Safe to call when already running.
    public func start() {
        queue.async { self.startLocked() }
    }

    /// Stops advertising and listening. A transfer already under way is cut off only when `dropConnections` is true.
    public func stop(dropConnections: Bool = true) {
        queue.async { self.stopLocked(dropConnections: dropConnections) }
    }

    /// Re-creates the listener and the mDNS record (network change, wake). Connections in progress are dropped only when asked.
    public func restart(dropConnections: Bool) {
        queue.async {
            guard self.listener != nil else { return }
            self.stopLocked(dropConnections: dropConnections)
            self.startLocked()
        }
    }

    /// Starts and waits for the listener's port. For tests.
    public func startAndWait(timeout: TimeInterval = 5) -> UInt16? {
        start()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let p = queue.sync(execute: { port }) { return p }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }

    private func startLocked() {
        guard listener == nil else { return }
        generation += 1
        let gen = generation
        let l: NWListener
        do { l = try NWListener(using: .tcp) } catch { log("quickshare: couldn't listen: \(error.localizedDescription)"); return }
        if advertise {
            let info = QSEndpoint.endpointInfo(name: deviceName())
            l.service = NWListener.Service(name: QSEndpoint.serviceName(endpointId: endpointId), type: QSEndpoint.serviceType,
                                           txtRecord: NWTXTRecord(["n": QSEndpoint.base64URL(info)]))
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l, gen == self.generation else { return }
            switch state {
            case .ready:
                self.port = l.port?.rawValue
                self.log("quickshare: listening on \(self.port ?? 0)\(self.advertise ? ", advertised" : "")")
                self.onListening?(self.port)
            case .failed(let err):
                self.log("quickshare: listener failed: \(err)")
                l.cancel()
                if self.listener === l { self.listener = nil; self.port = nil; self.onListening?(nil) }
            default: break
            }
        }
        listener = l
        l.start(queue: queue)
    }

    private func stopLocked(dropConnections: Bool) {
        generation += 1
        listener?.cancel()
        listener = nil
        port = nil
        if dropConnections { for c in Array(connections.values) { c.abort() } }
        onListening?(nil)
    }

    private func accept(_ nw: NWConnection) {
        guard connections.count < Self.maxConnections else { nw.cancel(); return }
        let id = UUID().uuidString.lowercased()
        let conn = QSNetConnection(id: id, connection: nw, queue: queue, delegate: self)
        conn.log = log
        connections[id] = conn
        conn.start()
    }

    // MARK: QSConnectionDelegate

    func qsConnection(_ id: String, request: QSRequest, respond: @escaping (QSDecision) -> Void) {
        if let onRequest { onRequest(request, respond) } else { respond(.reject) }
    }

    func qsConnection(_ id: String, event: QSConnectionEvent) {
        if case .finished = event { connections[id] = nil }
        onEvent?(id, event)
    }
}

/// Glue between one `NWConnection` and a `QSInboundConnection`: length-prefixed framing in both directions.
final class QSNetConnection {
    let id: String
    var log: (String) -> Void = { _ in }
    private let nw: NWConnection
    private let queue: DispatchQueue
    private var machine: QSInboundConnection!
    private var frames = QSFrameBuffer()
    private var closed = false

    init(id: String, connection: NWConnection, queue: DispatchQueue, delegate: QSConnectionDelegate) {
        self.id = id; self.nw = connection; self.queue = queue
        machine = QSInboundConnection(id: id, remoteHost: QSNetConnection.ipv4(of: connection.endpoint), queue: queue,
                                      sendFrame: { [weak self] d in self?.write(d) }, closeTransport: { [weak self] in self?.closeGracefully() })
        machine.delegate = delegate
    }

    func start() {
        nw.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled: self.transportGone()
            default: break
            }
        }
        nw.start(queue: queue)
        machine.start()
        receive()
    }

    /// The sender's IPv4 address, when it connected over IPv4.
    static func ipv4(of endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        var text = "\(host)"
        if let pct = text.firstIndex(of: "%") { text = String(text[..<pct]) }
        if text.hasPrefix("::ffff:") { text = String(text.dropFirst(7)) }
        let parts = text.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy({ UInt8($0) != nil }) ? text : nil
    }

    func abort() { machine.transportClosed(); nw.cancel() }

    private func transportGone() {
        guard !closed else { return }
        closed = true
        machine.transportClosed()
    }

    private func receive() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.frames.append(data)
                while let frame = self.nextFrame() {
                    self.machine.receive(frame)
                    if self.machine.isFinished { return }
                }
            }
            if error != nil || isComplete { self.transportGone(); self.nw.cancel(); return }
            self.receive()
        }
    }

    private func nextFrame() -> Data? {
        do { return try frames.next() } catch {
            closed = true
            nw.cancel()
            machine.transportClosed()
            return nil
        }
    }

    private func write(_ d: Data) {
        guard !closed else { return }
        nw.send(content: QSFrameBuffer.wrap(d), completion: .contentProcessed { _ in })
    }

    /// Lets queued writes drain, then closes.
    private func closeGracefully() {
        guard !closed else { return }
        closed = true
        nw.send(content: nil, isComplete: true, completion: .contentProcessed { [nw] _ in nw.cancel() })
    }
}

/// Length-prefixed framing for the Quick Share TCP stream: u32 big-endian length, then that many bytes.
struct QSFrameBuffer {
    enum Failure: Error { case tooLarge }
    private var buf = Data()
    let maxFrame: Int
    init(maxFrame: Int = QSInboundConnection.maxFrameLength) { self.maxFrame = maxFrame }

    mutating func append(_ d: Data) { buf.append(d) }

    /// The next complete frame body, or nil when more bytes are needed.
    mutating func next() throws -> Data? {
        guard buf.count >= 4 else { return nil }
        let s = buf.startIndex
        let len = Int(buf[s]) << 24 | Int(buf[s + 1]) << 16 | Int(buf[s + 2]) << 8 | Int(buf[s + 3])
        if len > maxFrame { throw Failure.tooLarge }
        guard buf.count >= 4 + len else { return nil }
        let body = Data(buf[(s + 4)..<(s + 4 + len)])
        buf = Data(buf.dropFirst(4 + len))
        return body
    }

    static func wrap(_ body: Data) -> Data {
        var out = Data(capacity: body.count + 4)
        let n = UInt32(body.count)
        out.append(contentsOf: [UInt8(n >> 24), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)])
        out.append(body)
        return out
    }
}

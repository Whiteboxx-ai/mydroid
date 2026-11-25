import Foundation
import Network

public struct HelloRequest: Sendable {
    public let phoneId: String
    public let macId: String
    public let pairing: Bool
}

public protocol ServerDelegate: AnyObject {
    /// LTK to use for this hello, or nil to reject the connection.
    func server(_ server: Server, ltkFor hello: HelloRequest) -> Data?
    /// The client proved it holds the LTK and `welcome` has been sent.
    func server(_ server: Server, peerAuthenticated peer: Peer, auth: Message)
    func server(_ server: Server, peer: Peer, received message: Message)
    func server(_ server: Server, peerClosed peer: Peer)
    func server(_ server: Server, listenerChanged port: UInt16?, error: String?)
}

/// One TCP connection from a phone.
public final class Peer {
    enum Phase { case awaitHello, awaitAuth, ready, closed }

    public let id = UUID()
    let connection: NWConnection
    var phase: Phase = .awaitHello
    var inbound = FrameBuffer()
    var sendCipher: FrameCipher?
    var recvCipher: FrameCipher?
    let connectedAt = Date()
    var lastReceived = Date()
    var idleProbeSent = false
    var wasAuthenticated = false
    unowned let server: Server

    public private(set) var phoneId = ""
    public private(set) var isPairing = false
    public private(set) var ltk = Data()
    public private(set) var confirmCode = ""
    public private(set) var phoneName = ""

    init(connection: NWConnection, server: Server) {
        self.connection = connection
        self.server = server
    }

    public var isReady: Bool { phase == .ready }

    /// The phone's IPv4 address, when it connected over IPv4 (or an IPv4-mapped IPv6 address).
    public var remoteIPv4: String? {
        guard case let .hostPort(host, _) = connection.endpoint else { return nil }
        var text = "\(host)"
        if let pct = text.firstIndex(of: "%") { text = String(text[..<pct]) }
        if text.hasPrefix("::ffff:") { text = String(text.dropFirst(7)) }
        let parts = text.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy({ UInt8($0) != nil }) ? text : nil
    }

    /// Must be called on the server queue. Messages are encrypted and sent in call order.
    public func send(_ message: Message, completion: (@Sendable (Bool) -> Void)? = nil) {
        guard phase != .closed, phase != .awaitHello, var cipher = sendCipher else { completion?(false); return }
        do {
            let frame = Framing.wrap(try cipher.seal(try message.encode()))
            sendCipher = cipher
            connection.send(content: frame, completion: .contentProcessed { err in completion?(err == nil) })
        } catch {
            completion?(false)
        }
    }

    public func close() { server.close(self) }

    func configure(hello: HelloRequest, ltk: Data, keys: MydroidCrypto.SessionKeys, code: String) {
        phoneId = hello.phoneId
        isPairing = hello.pairing
        self.ltk = ltk
        confirmCode = code
        sendCipher = FrameCipher(key: keys.s2c)
        recvCipher = FrameCipher(key: keys.c2s)
    }
    func setPhoneName(_ n: String) { phoneName = n }
}

/// Network.framework TCP server: listener, Bonjour, handshake and encrypted framing.
/// Everything runs on `queue`; delegate callbacks arrive there too.
public final class Server {
    public static let defaultPort: UInt16 = 47820

    public let queue: DispatchQueue
    public weak var delegate: ServerDelegate?
    public var log: (String) -> Void = { _ in }
    public private(set) var port: UInt16?

    private let macId: String
    private let macName: String
    private let advertise: Bool
    private let preferredPort: UInt16
    private var listener: NWListener?
    private var cancellingListener: NWListener?
    private var pendingPort: UInt16?
    private var peers: [UUID: Peer] = [:]
    private var heartbeat: DispatchSourceTimer?
    private var generation = 0

    public init(macId: String, macName: String, preferredPort: UInt16 = Server.defaultPort,
                advertise: Bool = true, queue: DispatchQueue) {
        self.macId = macId
        self.macName = macName
        self.preferredPort = preferredPort
        self.advertise = advertise
        self.queue = queue
    }

    // MARK: Listener

    /// Starts listening. Tries the preferred port first, then any free port.
    public func start() {
        start(on: preferredPort)
    }

    private func start(on requestedPort: UInt16) {
        generation += 1
        pendingPort = requestedPort
        cancelListener()
        launchWhenAvailable()
        startHeartbeat()
    }

    public func stopListener() {
        generation += 1
        pendingPort = nil
        cancelListener()
    }

    private func cancelListener() {
        guard let listener else { return }
        cancellingListener = listener
        listener.cancel()
        self.listener = nil
        port = nil
    }

    private func launchWhenAvailable() {
        // Cancellation is asynchronous. Binding early can collide with our own listening socket.
        guard cancellingListener == nil, let pendingPort else { return }
        self.pendingPort = nil
        launch(port: pendingPort == 0 ? nil : NWEndpoint.Port(rawValue: pendingPort), gen: generation)
    }

    /// Re-creates the listener (after wake, after a network change). Optionally drops connections.
    public func restart(dropConnections: Bool) {
        if dropConnections { for p in Array(peers.values) { close(p) } }
        start(on: port ?? pendingPort ?? preferredPort)
    }

    /// TCP_NODELAY on every session connection: pointer moves are tiny frames at up to 120 per second, and Nagle's algorithm
    /// would batch them (PROTOCOL.md 10). Accepted connections inherit these options from the listener.
    static func listenerParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        return params
    }

    private func launch(port requested: NWEndpoint.Port?, gen: Int) {
        let params = Self.listenerParameters()
        let l: NWListener
        do {
            l = try requested.map { try NWListener(using: params, on: $0) } ?? NWListener(using: params)
        } catch {
            report(error: "Couldn't listen: \(error.localizedDescription)")
            return
        }
        if advertise {
            l.service = NWListener.Service(type: "_mydroid._tcp", txtRecord: NWTXTRecord(["id": macId, "v": "1"]))
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l else { return }
            if case .cancelled = state, self.cancellingListener === l {
                self.cancellingListener = nil
                self.launchWhenAvailable()
                return
            }
            guard gen == self.generation else { return }
            switch state {
            case .ready:
                self.port = l.port?.rawValue
                self.log("listening on \(self.port ?? 0)")
                self.delegate?.server(self, listenerChanged: self.port, error: nil)
            case .failed(let err):
                l.cancel()
                if requested != nil {
                    self.log("port busy (\(err)); falling back to any port")
                    self.listener = nil
                    self.launch(port: nil, gen: gen)
                } else {
                    self.report(error: "Couldn't listen: \(err.localizedDescription)")
                }
            default: break
            }
        }
        listener = l
        l.start(queue: queue)
    }

    private func report(error: String) {
        log(error)
        delegate?.server(self, listenerChanged: nil, error: error)
    }

    /// PROTOCOL.md 5.2: keep the full receive-idle window for a phone resuming from Android Doze.
    public static let idleTimeout: TimeInterval = 240
    public static let handshakeTimeout: TimeInterval = 15
    private static let idleProbeDelay: TimeInterval = 100

    public static func isIdle(ready: Bool, since: Date, now: Date) -> Bool {
        now.timeIntervalSince(since) > (ready ? idleTimeout : handshakeTimeout)
    }

    static func shouldProbe(since: Date, now: Date) -> Bool {
        now.timeIntervalSince(since) >= idleProbeDelay
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date()
            for p in Array(self.peers.values) {
                let ready = p.phase == .ready
                let since = ready ? p.lastReceived : p.connectedAt
                if Server.isIdle(ready: ready, since: since, now: now) {
                    self.log("peer timed out")
                    self.close(p)
                } else if ready && !p.idleProbeSent && Server.shouldProbe(since: since, now: now) {
                    p.idleProbeSent = true
                    p.send(Message("ping"))
                }
            }
        }
        t.resume()
        heartbeat = t
    }

    public func shutdown() {
        heartbeat?.cancel(); heartbeat = nil
        stopListener()
        for p in Array(peers.values) { close(p) }
    }

    // MARK: Connections

    private func accept(_ conn: NWConnection) {
        let peer = Peer(connection: conn, server: self)
        peers[peer.id] = peer
        conn.stateUpdateHandler = { [weak self, weak peer] state in
            guard let self, let peer else { return }
            switch state {
            case .failed, .cancelled: self.close(peer)
            default: break
            }
        }
        conn.start(queue: queue)
        receive(peer)
    }

    func close(_ peer: Peer) {
        guard peer.phase != .closed else { return }
        let announce = peer.wasAuthenticated
        peer.phase = .closed
        peers[peer.id] = nil
        peer.connection.cancel()
        if announce { delegate?.server(self, peerClosed: peer) }
    }

    private func receive(_ peer: Peer) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self, weak peer] data, _, isComplete, error in
            guard let self, let peer, peer.phase != .closed else { return }
            if let data, !data.isEmpty {
                peer.inbound.append(data)
                do {
                    while let frame = try peer.inbound.next() {
                        self.handle(frame: frame, from: peer)
                        if peer.phase == .closed { return }
                    }
                } catch {
                    self.log("protocol error: frame too large")
                    self.close(peer)
                    return
                }
            }
            if error != nil || isComplete { self.close(peer); return }
            self.receive(peer)
        }
    }

    private func handle(frame: Data, from peer: Peer) {
        switch peer.phase {
        case .awaitHello: handleHello(frame, peer)
        case .awaitAuth, .ready: handleEncrypted(frame, peer)
        case .closed: break
        }
    }

    private func handleHello(_ frame: Data, _ peer: Peer) {
        guard let obj = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any],
              obj["t"] as? String == "hello",
              (obj["v"] as? NSNumber)?.intValue == 1,
              let phone = obj["phone"] as? String, let mac = obj["mac"] as? String,
              let nonceB64 = obj["nonce"] as? String, let nonceC = Data(base64Encoded: nonceB64), nonceC.count == 16
        else { log("bad hello"); close(peer); return }
        let pairing = (obj["pairing"] as? Bool) ?? false
        let req = HelloRequest(phoneId: phone, macId: mac, pairing: pairing)
        guard mac == macId, let ltk = delegate?.server(self, ltkFor: req) else {
            log("hello rejected"); close(peer); return
        }
        let nonceS = MydroidCrypto.randomBytes(16)
        let keys = MydroidCrypto.sessionKeys(ltk: ltk, nonceC: nonceC, nonceS: nonceS)
        let code = MydroidCrypto.confirmCode(ltk: ltk, nonceC: nonceC, nonceS: nonceS)
        let reply: [String: Any] = ["t": "hello", "v": 1, "mac": macId, "nonce": nonceS.base64EncodedString()]
        guard let json = try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes]) else { close(peer); return }
        peer.configure(hello: req, ltk: ltk, keys: keys, code: code)
        peer.phase = .awaitAuth
        peer.connection.send(content: Framing.wrap(json), completion: .contentProcessed { _ in })
    }

    private func handleEncrypted(_ frame: Data, _ peer: Peer) {
        guard var cipher = peer.recvCipher else { close(peer); return }
        let plaintext: Data
        do { plaintext = try cipher.open(frame) } catch {
            log("decrypt failed: \(error)"); close(peer); return
        }
        peer.recvCipher = cipher
        guard let msg = try? Message.decode(plaintext) else { log("undecodable message"); return }
        peer.lastReceived = Date()
        peer.idleProbeSent = false
        if peer.phase == .awaitAuth {
            guard msg.type == "auth" else { log("expected auth"); close(peer); return }
            peer.setPhoneName(msg.string("name") ?? msg.string("model") ?? "Android phone")
            peer.phase = .ready
            peer.wasAuthenticated = true
            peer.send(Message("welcome", ["name": macName]))
            delegate?.server(self, peerAuthenticated: peer, auth: msg)
        } else {
            delegate?.server(self, peer: peer, received: msg)
        }
    }
}

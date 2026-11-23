import Foundation
import Darwin

// The link between `mydroid-nmhost` and the running Mydroid app: one request line and one reply line of JSON on a Unix socket
// (`otp.sock`, mode 0600, same-user peers only). One connection per request, so a slow phone approval never blocks another request.

public enum OTPSocket {
    public static let fileName = "otp.sock"
    public static let launchBundleID = "com.mydroid.mac"
    /// Lines (requests and replies) are small.
    public static let maxLine = 256 * 1024

    /// `~/Library/Application Support/Mydroid/otp.sock`, or `$MYDROID_DATA_DIR/otp.sock` in developer mode (so a dev run never touches the real app's socket).
    public static func defaultPath(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                   env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let dev = env["MYDROID_DATA_DIR"], !dev.isEmpty { return URL(fileURLWithPath: dev, isDirectory: true).appendingPathComponent(fileName).path }
        return home.appendingPathComponent("Library/Application Support/Mydroid", isDirectory: true).appendingPathComponent(fileName).path
    }

    public enum Failure: Error, Equatable {
        case pathTooLong, noServer, inUse, timeout, io(String), tooLarge
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw Failure.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        return addr
    }

    static func connectFD(_ path: String) throws -> Int32 {
        var addr = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.io("socket") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if rc != 0 { close(fd); throw Failure.noServer }
        return fd
    }

    static func setTimeouts(_ fd: Int32, seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var sent = 0
        return data.withUnsafeBytes { raw -> Bool in
            while sent < data.count {
                let n = write(fd, raw.baseAddress!.advanced(by: sent), data.count - sent)
                if n < 0 { if errno == EINTR { continue }; return false }
                if n == 0 { return false }
                sent += n
            }
            return true
        }
    }

    /// One line (without its newline), or nil on EOF/timeout/too long. `timedOut` says which.
    static func readLine(_ fd: Int32, timedOut: inout Bool) -> Data? {
        var line = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { timedOut = true }
                return nil
            }
            if n == 0 { return line.isEmpty ? nil : line }
            if let nl = chunk[0..<n].firstIndex(of: 0x0A) {
                line.append(contentsOf: chunk[0..<nl])
                return line
            }
            line.append(contentsOf: chunk[0..<n])
            if line.count > maxLine { return nil }
        }
    }

    // MARK: Client

    /// Sends one request line and waits for the reply line. Blocking.
    public static func request(path: String, payload: Data, timeout: TimeInterval = 45) throws -> Data {
        guard payload.count <= maxLine, !payload.contains(0x0A) else { throw Failure.tooLarge }
        let fd = try connectFD(path)
        defer { close(fd) }
        setTimeouts(fd, seconds: timeout)
        guard writeAll(fd, payload + Data([0x0A])) else { throw Failure.io("write") }
        var timedOut = false
        guard let reply = readLine(fd, timedOut: &timedOut) else { throw timedOut ? Failure.timeout : Failure.io("read") }
        return reply
    }

    /// Like `request`, but if nobody is listening it calls `launch` once and keeps trying for `launchWait` seconds.
    public static func request(path: String, payload: Data, timeout: TimeInterval = 45,
                               launch: () -> Void, launchWait: TimeInterval = 8) throws -> Data {
        do { return try request(path: path, payload: payload, timeout: timeout) }
        catch Failure.noServer {
            launch()
            let deadline = Date().addingTimeInterval(launchWait)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.25)
                do { return try request(path: path, payload: payload, timeout: timeout) }
                catch Failure.noServer { continue }
            }
            throw Failure.noServer
        }
    }

    /// Whether a live server answers on this path.
    public static func isServing(path: String) -> Bool {
        guard let fd = try? connectFD(path) else { return false }
        close(fd); return true
    }
}

/// The app side: accepts connections, checks the peer is the same user, reads one line and answers with one line.
public final class OTPSocketServer: @unchecked Sendable {
    public typealias Responder = (_ request: Data, _ reply: @escaping @Sendable (Data) -> Void) -> Void

    public let path: String
    private let responder: Responder
    private let log: (String) -> Void
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false

    public init(path: String, log: @escaping (String) -> Void = { _ in }, responder: @escaping Responder) {
        self.path = path; self.responder = responder; self.log = log
    }

    /// Binds the socket (mode 0600, in a 0700 folder). Throws `inUse` when another live process already serves this path; a stale file is replaced.
    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        chmod(dir, 0o700)
        if OTPSocket.isServing(path: path) { throw OTPSocket.Failure.inUse }
        unlink(path)
        var addr = try OTPSocket.address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw OTPSocket.Failure.io("socket") }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { close(fd); throw OTPSocket.Failure.io("bind") }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { close(fd); unlink(path); throw OTPSocket.Failure.io("listen") }
        listenFD = fd
        running = true
        let t = Thread { [weak self] in self?.acceptLoop(fd) }
        t.name = "mydroid.otp.accept"
        t.start()
    }

    public func stop() {
        lock.lock()
        let fd = listenFD
        let was = running
        running = false; listenFD = -1
        lock.unlock()
        guard was else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(path)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 {
                if errno == EINTR { continue }
                return                                   // closed by stop()
            }
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(c, &uid, &gid) == 0, uid == geteuid() else {
                log("otp socket: refused a connection from another user")
                close(c); continue
            }
            OTPSocket.setTimeouts(c, seconds: 5)          // the request line has to arrive promptly
            let t = Thread { [responder] in
                var timedOut = false
                guard let line = OTPSocket.readLine(c, timedOut: &timedOut) else { close(c); return }
                OTPSocket.setTimeouts(c, seconds: 60)
                responder(line) { reply in
                    _ = OTPSocket.writeAll(c, reply + Data([0x0A]))
                    close(c)
                }
            }
            t.name = "mydroid.otp.conn"
            t.start()
        }
    }
}

import Foundation
import Darwin
import MydroidCore

// Runs an adb (Android platform-tools). Mydroid has its own adb server on its own port and its own key home, so it
// never fights a developer's adb on 5037 or touches their ~/.android. A separate client can
// talk to a developer server that is already running, without starting or stopping it.

struct AdbResult: Sendable {
    var status: Int32
    var out: String
    var err: String
    var timedOut = false
    var ok: Bool { status == 0 && !timedOut }
    var text: String { out + err }
}

/// A long-running `adb shell` for the call-audio helper: JSON lines in and out.
protocol HelperProcess: AnyObject {
    var onLine: ((String) -> Void)? { get set }
    var onExit: ((Int32) -> Void)? { get set }
    /// False if the process couldn't be started.
    func start() -> Bool
    func send(_ line: String)
    /// Asks the helper to quit, then makes sure it is gone.
    func stop()
}

protocol AdbControlling: AnyObject {
    /// False in a build that doesn't contain adb.
    var isAvailable: Bool { get }
    func ensureServer() async -> Bool
    func mdnsServices() async -> [AdbMdnsService]
    func onlineDevices() async -> [AdbParsing.Device]
    func pair(endpoint: String, password: String) async -> AdbResult
    func connect(endpoint: String) async -> AdbResult
    /// `nil` disconnects everything.
    func disconnect(endpoint: String?) async
    func shell(serial: String, _ command: String, timeout: TimeInterval) async -> AdbResult
    func isOnline(serial: String) async -> Bool
    func makeHelper(serial: String, package: CallAudioAndroidPackage) -> HelperProcess
    func killServer()
}

extension AdbControlling {
    func onlineDevices() async -> [AdbParsing.Device] { [] }
}

final class AdbClient: AdbControlling, @unchecked Sendable {
    static let defaultPort = 5099

    private let executable: URL?
    private let port: Int
    private let home: URL
    private let existingServer: Bool
    private var serverStarted = false
    private var clientVersion: Int?
    private let lock = NSLock()
    var log: (String) -> Void = { _ in }

    init(executable: URL? = AdbClient.locate(), port: Int = AdbClient.defaultPort, home: URL, existingServer: Bool = false) {
        self.executable = executable
        self.port = port
        self.home = home
        self.existingServer = existingServer
        signal(SIGPIPE, SIG_IGN)       // a helper that has gone away must not take the app with it
    }

    var isAvailable: Bool { executable != nil }

    /// `Contents/Resources/adb` in the app, `MYDROID_ADB` for development, then the Android SDK on this Mac.
    static func locate() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent("adb")) }
        if let e = ProcessInfo.processInfo.environment["MYDROID_ADB"] { candidates.append(URL(fileURLWithPath: e)) }
        candidates.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk/platform-tools/adb"))
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    private var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["ADB_SERVER_SOCKET"] = "tcp:localhost:\(port)"
        env["ANDROID_ADB_SERVER_PORT"] = "\(port)"
        env["HOME"] = home.path                 // adb keeps its key in $HOME/.android: Mydroid gets its own
        env["ADB_MDNS_AUTO_CONNECT"] = "0"      // we connect explicitly, so serials are always host:port
        env.removeValue(forKey: "ANDROID_SERIAL")
        return env
    }

    private func makeProcess(_ args: [String]) -> Process? {
        guard let executable else { return nil }
        if existingServer, args != ["version"], !existingServerIsCompatible() { return nil }
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let p = Process()
        p.executableURL = executable
        // An explicit host tells adb to use the existing server, even when it is on localhost.
        p.arguments = existingServer ? ["-H", "127.0.0.1", "-P", String(port)] + args : args
        p.environment = environment
        return p
    }

    private func existingServerIsCompatible() -> Bool {
        // The adb CLI can kill a server if the protocol versions differ. Query the
        // loopback server directly before letting the CLI touch a developer's session.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return false }
        let request = Array("000chost:version".utf8)
        guard send(fd, request, request.count, 0) == request.count else { return false }
        var response = [UInt8](repeating: 0, count: 12)
        guard recv(fd, &response, response.count, MSG_WAITALL) == response.count,
              response.prefix(8).elementsEqual("OKAY0004".utf8),
              let remoteVersion = Int(String(decoding: response.suffix(4), as: UTF8.self), radix: 16) else { return false }
        if let version = lock.withLock({ clientVersion }) { return version == remoteVersion }
        let output = runSync(["version"], timeout: 2).out
        let line = output.split(whereSeparator: \.isNewline).first
        guard let version = line?.split(separator: ".").last.flatMap({ Int($0) }) else { return false }
        lock.withLock { clientVersion = version }
        return version == remoteVersion
    }

    /// Runs adb and waits (off the main thread). Kills it after `timeout` seconds.
    func run(_ args: [String], timeout: TimeInterval = 15) async -> AdbResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: self.runSync(args, timeout: timeout))
            }
        }
    }

    func runSync(_ args: [String], timeout: TimeInterval) -> AdbResult {
        guard let p = makeProcess(args) else { return AdbResult(status: 127, out: "", err: "adb isn't part of this build") }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        do { try p.run() } catch { return AdbResult(status: 126, out: "", err: "\(error.localizedDescription)") }
        group.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        var timedOut = false
        let killer = DispatchWorkItem { timedOut = true; p.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        p.waitUntilExit()
        killer.cancel()
        group.wait()
        return AdbResult(status: p.terminationStatus, out: String(decoding: outData, as: UTF8.self),
                         err: String(decoding: errData, as: UTF8.self), timedOut: timedOut)
    }

    // MARK: AdbControlling

    func ensureServer() async -> Bool {
        guard isAvailable else { return false }
        if existingServer { return await run(["devices"], timeout: 3).ok }
        if lock.withLock({ serverStarted }) {
            // Still answering?
            let r = await run(["get-state"], timeout: 5)
            if !r.text.contains("cannot connect to daemon") { return true }
        }
        // The server forks from this call; its output goes nowhere so the pipes can close.
        let ok: Bool = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let p = self.makeProcess(["start-server"]) else { cont.resume(returning: false); return }
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: false); return }
                let killer = DispatchWorkItem { p.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: killer)
                p.waitUntilExit()
                killer.cancel()
                cont.resume(returning: p.terminationStatus == 0)
            }
        }
        if ok { lock.withLock { serverStarted = true } }
        log("adb server \(ok ? "ready" : "did not start") on port \(port)")
        return ok
    }

    func mdnsServices() async -> [AdbMdnsService] {
        let r = await run(["mdns", "services"], timeout: 8)
        return r.ok ? AdbParsing.mdnsServices(r.out) : []
    }

    func onlineDevices() async -> [AdbParsing.Device] {
        let r = await run(["devices"], timeout: 3)
        return r.ok ? AdbParsing.devices(r.out).filter { $0.state == "device" } : []
    }

    func pair(endpoint: String, password: String) async -> AdbResult {
        await run(["pair", endpoint, password], timeout: 25)
    }

    func connect(endpoint: String) async -> AdbResult {
        await run(["connect", endpoint], timeout: 20)
    }

    func disconnect(endpoint: String?) async {
        _ = await run(endpoint.map { ["disconnect", $0] } ?? ["disconnect"], timeout: 8)
    }

    func shell(serial: String, _ command: String, timeout: TimeInterval = 15) async -> AdbResult {
        await run(["-s", serial, "shell", command], timeout: timeout)
    }

    func isOnline(serial: String) async -> Bool {
        let r = await run(["-s", serial, "get-state"], timeout: 6)
        return r.ok && r.out.trimmingCharacters(in: .whitespacesAndNewlines) == "device"
    }

    func makeHelper(serial: String, package: CallAudioAndroidPackage) -> HelperProcess {
        let p = makeProcess(["-s", serial, "shell", package.launchCommand])
        return AdbHelperProcess(process: p)
    }

    func killServer() {
        guard lock.withLock({ serverStarted }) else { return }
        _ = runSync(["kill-server"], timeout: 3)
        lock.withLock { serverStarted = false }
    }
}

/// The helper as an `adb shell` child: JSON lines on stdin and stdout. Levels and counts only ever come back; audio goes over UDP.
final class AdbHelperProcess: HelperProcess, @unchecked Sendable {
    var onLine: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    private let process: Process?
    private let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    private var lines = LineBuffer()
    private let io = DispatchQueue(label: "com.mydroid.helper.io")
    private var stopped = false

    init(process: Process?) { self.process = process }

    func start() -> Bool {
        guard let p = process else { return false }
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self else { return }
            if d.isEmpty { h.readabilityHandler = nil; return }
            self.io.async { for l in self.lines.append(d) { self.onLine?(l) } }
        }
        stderr.fileHandleForReading.readabilityHandler = { h in if h.availableData.isEmpty { h.readabilityHandler = nil } }   // drained, never kept
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.stdout.fileHandleForReading.readabilityHandler = nil
            self.stderr.fileHandleForReading.readabilityHandler = nil
            self.io.async { self.onExit?(proc.terminationStatus) }
        }
        do { try p.run() } catch { return false }
        return true
    }

    func send(_ line: String) {
        io.async { [weak self] in
            guard let self, !self.stopped, self.process?.isRunning == true else { return }
            try? self.stdin.fileHandleForWriting.write(contentsOf: Data(line.utf8))
        }
    }

    func stop() {
        io.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.stopped = true
            try? self.stdin.fileHandleForWriting.write(contentsOf: Data(HelperProtocol.quit.utf8))
            try? self.stdin.fileHandleForWriting.close()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.process?.isRunning == true { self?.process?.terminate() }
        }
    }
}

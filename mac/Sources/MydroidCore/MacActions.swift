import Foundation

// PROTOCOL.md section 11: quick actions from the phone and the Mac's status.

public enum MacAction: Equatable, Sendable {
    case lock, sleep, displaySleep, ring, ringStop
    case shortcut(String)

    /// Longest Shortcut name accepted.
    public static let maxShortcutName = 200

    public init?(message m: Message) {
        switch m.string("action") {
        case "lock": self = .lock
        case "sleep": self = .sleep
        case "displaysleep": self = .displaySleep
        case "ring": self = .ring
        case "ringstop": self = .ringStop
        case "shortcut":
            guard let n = m.string("name") else { return nil }
            self = .shortcut(n)
        default: return nil
        }
    }
}

public struct MacActionResult: Equatable, Sendable {
    public var ok: Bool
    public var error: String?
    /// Extra detail on a success the phone may want to show ("The display was put to sleep instead").
    public var note: String?
    public init(ok: Bool, error: String? = nil, note: String? = nil) { self.ok = ok; self.error = error; self.note = note }
    public static let success = MacActionResult(ok: true)
    public static func failure(_ why: String) -> MacActionResult { MacActionResult(ok: false, error: why) }
}

/// What the Hub calls for `mac.action` and `mac.shortcuts.get`. Completions may come from any queue.
public protocol MacActionPerforming: AnyObject {
    func perform(_ action: MacAction, completion: @escaping @Sendable (MacActionResult) -> Void)
    func listShortcuts(completion: @escaping @Sendable (Result<[String], MacActionFailure>) -> Void)
}

public struct MacActionFailure: Error, Equatable, Sendable {
    public var message: String
    public init(_ m: String) { message = m }
}

public protocol AccessibilityChecking: AnyObject {
    var isTrusted: Bool { get }
}

/// Starts and stops the loud "your phone is looking for this Mac" ring. May be called from any thread.
public protocol RingControlling: AnyObject {
    func startRinging()
    func stopRinging()
}

public struct CommandResult: Equatable, Sendable {
    public var status: Int32
    public var output: String
    public var error: String
    /// The command was still running when `answerAfter` passed. It is left running.
    public var stillRunning: Bool
    public var launchFailed: Bool
    public init(status: Int32 = 0, output: String = "", error: String = "", stillRunning: Bool = false, launchFailed: Bool = false) {
        self.status = status; self.output = output; self.error = error; self.stillRunning = stillRunning; self.launchFailed = launchFailed
    }
}

public protocol CommandRunning: AnyObject {
    /// Runs `path` with `arguments` (no shell). Calls `completion` once: when the command exits, or when `answerAfter` seconds pass
    /// and it hasn't (`stillRunning`; with `killOnTimeout` it is terminated first).
    func run(_ path: String, _ arguments: [String], answerAfter: TimeInterval, killOnTimeout: Bool,
             completion: @escaping @Sendable (CommandResult) -> Void)
}

/// Foundation `Process`, no shell, output capped.
public final class ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(_ path: String, _ arguments: [String], answerAfter: TimeInterval, killOnTimeout: Bool,
                    completion: @escaping @Sendable (CommandResult) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let box = Once(completion)
        let outData = Capped(), errData = Capped()
        out.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; if d.isEmpty { h.readabilityHandler = nil } else { outData.append(d) } }
        err.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; if d.isEmpty { h.readabilityHandler = nil } else { errData.append(d) } }
        p.terminationHandler = { proc in
            // Let the readers drain.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                box.fire(CommandResult(status: proc.terminationStatus, output: outData.string, error: errData.string))
            }
        }
        do { try p.run() } catch {
            completion(CommandResult(status: -1, error: error.localizedDescription, launchFailed: true))
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + answerAfter) {
            guard p.isRunning else { return }
            if killOnTimeout { p.terminate() }
            box.fire(CommandResult(status: 0, output: outData.string, error: errData.string, stillRunning: !killOnTimeout))
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock(); private var done = false; private let f: @Sendable (CommandResult) -> Void
        init(_ f: @escaping @Sendable (CommandResult) -> Void) { self.f = f }
        func fire(_ r: CommandResult) { lock.lock(); let go = !done; done = true; lock.unlock(); if go { f(r) } }
    }
    private final class Capped: @unchecked Sendable {
        private let lock = NSLock(); private var data = Data()
        func append(_ d: Data) { lock.lock(); if data.count < 256 * 1024 { data.append(d) }; lock.unlock() }
        var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }
}

/// The quick actions. Every system effect goes through a protocol, so tests post nothing, lock nothing and ring nothing.
public final class MacActionService: MacActionPerforming {
    private let accessibility: AccessibilityChecking
    private let poster: SyntheticEventPoster
    private let runner: CommandRunning
    private let ring: RingControlling

    /// How long a Shortcut may run before the phone is told it has started. A shortcut that doesn't exist or fails to start exits sooner.
    public static let shortcutAnswerAfter: TimeInterval = 3

    public init(accessibility: AccessibilityChecking, poster: SyntheticEventPoster, runner: CommandRunning, ring: RingControlling) {
        self.accessibility = accessibility; self.poster = poster; self.runner = runner; self.ring = ring
    }

    public func perform(_ action: MacAction, completion: @escaping @Sendable (MacActionResult) -> Void) {
        switch action {
        case .lock: lock(completion)
        case .sleep: pmset("sleepnow", completion)
        case .displaySleep: pmset("displaysleepnow", completion)
        case .ring: ring.startRinging(); completion(.success)
        case .ringStop: ring.stopRinging(); completion(.success)
        case let .shortcut(name): runShortcut(name, completion)
        }
    }

    /// Control-Command-Q. Needs Accessibility. Without it the display is put to sleep, which locks the Mac when
    /// "Require password after screen saver begins or display is turned off" is set to immediately; the result says so.
    private func lock(_ completion: @escaping @Sendable (MacActionResult) -> Void) {
        if accessibility.isTrusted {
            let flags: ModifierFlags = [.control, .command]
            poster.post(.key(code: 0x0C, down: true, flags: flags))
            poster.post(.key(code: 0x0C, down: false, flags: flags))
            completion(.success)
        } else {
            pmset("displaysleepnow") { r in
                completion(r.ok ? MacActionResult(ok: true, note: "displaysleep") : r)
            }
        }
    }

    private func pmset(_ verb: String, _ completion: @escaping @Sendable (MacActionResult) -> Void) {
        runner.run("/usr/bin/pmset", [verb], answerAfter: 5, killOnTimeout: true) { r in
            if r.launchFailed || r.status != 0 || r.stillRunning { completion(.failure("The Mac wouldn't do that")) } else { completion(.success) }
        }
    }

    /// A name is passed as one argument (no shell). Names that are empty, huge, hold control characters or start with "-" are refused.
    public static func validShortcutName(_ n: String) -> Bool {
        let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t.count <= MacAction.maxShortcutName && !t.hasPrefix("-")
            && t.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private func runShortcut(_ name: String, _ completion: @escaping @Sendable (MacActionResult) -> Void) {
        guard Self.validShortcutName(name) else { completion(.failure("That Shortcut name isn't valid")); return }
        runner.run("/usr/bin/shortcuts", ["run", name], answerAfter: Self.shortcutAnswerAfter, killOnTimeout: false) { r in
            if r.launchFailed { completion(.failure("Shortcuts isn't available on this Mac")) }
            else if r.stillRunning || r.status == 0 { completion(.success) }
            else { completion(.failure("Couldn't run the Shortcut \u{201C}\(name)\u{201D}")) }
        }
    }

    public func listShortcuts(completion: @escaping @Sendable (Result<[String], MacActionFailure>) -> Void) {
        runner.run("/usr/bin/shortcuts", ["list"], answerAfter: 10, killOnTimeout: true) { r in
            if r.launchFailed { completion(.failure(MacActionFailure("Shortcuts isn't available on this Mac"))) }
            else if r.stillRunning || r.status != 0 { completion(.failure(MacActionFailure("Couldn't read your Shortcuts"))) }
            else { completion(.success(Self.parseShortcuts(r.output))) }
        }
    }

    /// `shortcuts list` prints one name per line.
    public static func parseShortcuts(_ output: String, limit: Int = 500) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let n = line.trimmingCharacters(in: .whitespaces)
            if n.isEmpty || !seen.insert(n).inserted { continue }
            out.append(n)
            if out.count >= limit { break }
        }
        return out
    }
}

/// `mac.status` (PROTOCOL.md 11). Sent on connect and when something changes, never on a timer.
public struct MacStatus: Equatable, Sendable {
    public var name: String
    public var model: String
    /// nil on a desktop Mac.
    public var battery: Int?
    public var charging: Bool
    public var locked: Bool
    public var displayAsleep: Bool

    public init(name: String, model: String = "", battery: Int? = nil, charging: Bool = false, locked: Bool = false, displayAsleep: Bool = false) {
        self.name = name; self.model = model; self.battery = battery; self.charging = charging
        self.locked = locked; self.displayAsleep = displayAsleep
    }

    public var wireFields: [String: Any] {
        ["name": name, "model": model, "battery": battery.map { $0 as Any } ?? NSNull(), "charging": charging,
         "locked": locked, "displayAsleep": displayAsleep]
    }
}

/// `remote.state` (PROTOCOL.md 10).
public struct RemoteStatus: Equatable, Sendable {
    public var accessibility: Bool
    /// The app that is presenting, or nil.
    public var presenting: String?
    public init(accessibility: Bool = false, presenting: String? = nil) { self.accessibility = accessibility; self.presenting = presenting }

    public var wireFields: [String: Any] {
        ["accessibility": accessibility, "presenting": presenting.map { ["app": $0] as Any } ?? NSNull()]
    }
}

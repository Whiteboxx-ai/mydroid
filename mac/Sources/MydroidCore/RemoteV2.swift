import Foundation

// PROTOCOL.md section 16: apps and opening files, presenting, and the Mac's own media.
// Everything that touches the real system goes through a protocol here, so tests drive it with fakes.

// MARK: - System seams

public struct MacAppInfo: Equatable, Sendable {
    public var id: String
    public var name: String
    /// PNG, about 96 px. Only running apps carry one.
    public var icon: Data?
    public init(id: String, name: String, icon: Data? = nil) { self.id = id; self.name = name; self.icon = icon }
}

/// NSWorkspace, behind a protocol. Completions may come from any queue.
public protocol AppWorkspace: AnyObject {
    /// Dock apps that are running, most recently active first, with icons for the first `limit`.
    func runningApps(limit: Int) -> [MacAppInfo]
    func installedApps() -> [MacAppInfo]
    func isRunning(_ bundleId: String) -> Bool
    func frontmostBundleId() -> String?
    func launch(_ bundleId: String, completion: @escaping @Sendable (MacActionResult) -> Void)
    func open(_ url: URL, completion: @escaping @Sendable (MacActionResult) -> Void)
    /// The bundle id of the app that opens `url` by default.
    func defaultAppId(for url: URL) -> String?
}

public enum ScriptOutcome: Equatable, Sendable {
    /// The script's result, one string per list item.
    case ok([String])
    /// macOS has not let Mydroid control that app yet.
    case denied
    case failed(String)
}

/// Runs AppleScript. Results come back as the list the script returns.
public protocol ScriptRunning: AnyObject {
    func run(_ source: String, completion: @escaping @Sendable (ScriptOutcome) -> Void)
    /// A script that returns picture data (album art). Nil when there is none.
    func runData(_ source: String, completion: @escaping @Sendable (Data?) -> Void)
}

/// Picture work that needs AppKit: scale and encode artwork, and fetch an artwork URL.
public protocol ArtworkEncoding: AnyObject {
    func jpeg(from data: Data, maxPixel: Int) -> Data?
    func fetch(_ url: URL, completion: @escaping @Sendable (Data?) -> Void)
}

/// `osascript`, one process per call: it can be killed when an app hangs, and it never blocks the app's own threads.
/// Lists come back joined by the ASCII unit separator, so a comma in a song title is only a comma.
public final class OsascriptRunner: ScriptRunning {
    static let separator = "\u{1F}"
    private let runner: CommandRunning
    private let timeout: TimeInterval

    public init(runner: CommandRunning = ProcessCommandRunner(), timeout: TimeInterval = 4) { self.runner = runner; self.timeout = timeout }

    public func run(_ source: String, completion: @escaping @Sendable (ScriptOutcome) -> Void) {
        let wrapped = "set AppleScript's text item delimiters to (ASCII character 31)\n" + source
        runner.run("/usr/bin/osascript", ["-e", wrapped], answerAfter: timeout, killOnTimeout: true) { r in
            completion(Self.outcome(r))
        }
    }

    public func runData(_ source: String, completion: @escaping @Sendable (Data?) -> Void) {
        runner.run("/usr/bin/osascript", ["-e", source], answerAfter: timeout, killOnTimeout: true) { r in
            completion(r.status == 0 ? Self.dataLiteral(r.output) : nil)
        }
    }

    static func outcome(_ r: CommandResult) -> ScriptOutcome {
        if r.launchFailed { return .failed("couldn't run osascript") }
        if r.stillRunning { return .failed("timeout") }
        if r.status != 0 {
            let e = r.error
            if e.contains("-1743") || e.localizedCaseInsensitiveContains("not authorized") { return .denied }
            return .failed(String(e.prefix(200)))
        }
        let text = r.output.trimmingCharacters(in: .newlines)
        return .ok(text.isEmpty ? [] : text.components(separatedBy: separator))
    }

    /// `«data TIFF4d4d002a…»`: the four letters are the type, the rest is hex.
    static func dataLiteral(_ output: String) -> Data? {
        guard let open = output.range(of: "«data "), let close = output.range(of: "»", range: open.upperBound..<output.endIndex) else { return nil }
        let body = output[open.upperBound..<close.lowerBound].dropFirst(4)
        guard body.count % 2 == 0, !body.isEmpty else { return nil }
        var data = Data(capacity: body.count / 2)
        var i = body.startIndex
        while i < body.endIndex {
            let j = body.index(i, offsetBy: 2)
            guard let b = UInt8(body[i..<j], radix: 16) else { return nil }
            data.append(b)
            i = j
        }
        return data
    }
}

// MARK: - What the Hub calls

public struct AppsListing: Equatable, Sendable {
    public var running: [MacAppInfo]
    public var installed: [MacAppInfo]
    public init(running: [MacAppInfo], installed: [MacAppInfo]) { self.running = running; self.installed = installed }
}

public enum MacMediaCommand: Equatable, Sendable {
    case toggle, next, prev
    case seek(positionMs: Int64)
    case volume(Double)

    public init?(message m: Message) {
        switch m.string("action") {
        case "toggle": self = .toggle
        case "next": self = .next
        case "prev": self = .prev
        case "seek": guard let p = m.int("position"), p >= 0 else { return nil }; self = .seek(positionMs: p)
        case "volume": guard let v = m.double("value") else { return nil }; self = .volume(min(1, max(0, v)))
        default: return nil
        }
    }
}

/// The Hub's side of PROTOCOL.md 16. Completions may come from any queue.
public protocol MacRemoteHandling: AnyObject {
    func apps(completion: @escaping @Sendable (AppsListing) -> Void)
    func launch(_ bundleId: String, completion: @escaping @Sendable (MacActionResult) -> Void)
    func open(_ url: URL, completion: @escaping @Sendable (MacActionResult) -> Void)
    func present(_ url: URL, play: Bool, completion: @escaping @Sendable (MacActionResult) -> Void)
    func setPresentWatching(_ on: Bool)
    func setMediaWatching(_ on: Bool)
    func mediaCommand(_ c: MacMediaCommand)
}

// MARK: - Wire shapes

/// `present.state` (section 16.2).
public struct PresentState: Equatable, Sendable {
    public var active: Bool
    public var app: String?
    public var index: Int?
    public var count: Int?
    public var notes: String?
    public var title: String?
    /// `"automation"`: macOS hasn't let Mydroid control the app, so only `active` and `app` are known.
    public var error: String?

    public static let notPresenting = PresentState(active: false)
    public static let maxNotesBytes = 4096

    public init(active: Bool, app: String? = nil, index: Int? = nil, count: Int? = nil, notes: String? = nil, title: String? = nil, error: String? = nil) {
        self.active = active; self.app = app; self.index = index; self.count = count; self.notes = notes; self.title = title; self.error = error
    }

    var wireFields: [String: Any] {
        var f: [String: Any] = ["active": active]
        guard active else { return f }
        if let app { f["app"] = app }
        if let index { f["index"] = index }
        if let count { f["count"] = count }
        if let notes, !notes.isEmpty { f["notes"] = Self.clip(notes) }
        if let title, !title.isEmpty { f["title"] = String(title.prefix(200)) }
        if let error { f["error"] = error }
        return f
    }

    /// At most 4 KB of UTF-8, never cutting a character in half.
    static func clip(_ s: String) -> String {
        guard s.utf8.count > maxNotesBytes else { return s }
        var out = ""
        for ch in s {
            if out.utf8.count + String(ch).utf8.count > maxNotesBytes { break }
            out.append(ch)
        }
        return out
    }
}

/// `mac.media` (section 16.3).
public struct MacMedia: Equatable, Sendable {
    public var active: Bool
    public var app: String?
    public var title: String?
    public var artist: String?
    public var album: String?
    public var playing: Bool
    public var positionMs: Int64
    public var durationMs: Int64
    /// When `positionMs` was read, ms since 1970.
    public var ts: Int64
    public var canSeek: Bool
    /// JPEG, only on the message that follows a track change.
    public var art: Data?
    /// The system output volume, 0 to 1.
    public var volume: Double?
    public var error: String?

    public init(active: Bool, app: String? = nil, title: String? = nil, artist: String? = nil, album: String? = nil, playing: Bool = false,
                positionMs: Int64 = 0, durationMs: Int64 = 0, ts: Int64 = 0, canSeek: Bool = true, art: Data? = nil, volume: Double? = nil, error: String? = nil) {
        self.active = active; self.app = app; self.title = title; self.artist = artist; self.album = album; self.playing = playing
        self.positionMs = positionMs; self.durationMs = durationMs; self.ts = ts; self.canSeek = canSeek; self.art = art; self.volume = volume; self.error = error
    }

    var trackKey: String { [app ?? "", title ?? "", artist ?? "", album ?? ""].joined(separator: "\u{1F}") }

    var wireFields: [String: Any] {
        var f: [String: Any] = ["active": active]
        if let volume { f["volume"] = (volume * 1000).rounded() / 1000 }
        if let error { f["error"] = error }
        guard active else { return f }
        f["app"] = app ?? ""; f["title"] = title ?? ""; f["artist"] = artist ?? ""; f["album"] = album ?? ""
        f["playing"] = playing; f["position"] = positionMs; f["duration"] = durationMs; f["ts"] = ts; f["canSeek"] = canSeek
        if let art, !art.isEmpty { f["art"] = art.base64EncodedString() }
        return f
    }
}

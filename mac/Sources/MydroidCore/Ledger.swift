import Foundation

public struct LedgerEntry: Codable, Sendable, Equatable {
    public var xid: String
    public var kind: String
    public var path: String
    public var name: String
    public var size: Int64
    public var taken: Date?
    public var savedAt: Date
}

/// Dedupe ledger: which transfers are already on this Mac, plus partial files for resume.
/// Persisted as JSON. Not thread-safe by itself; the Hub uses it on its queue.
public final class TransferLedger {
    struct Stored: Codable {
        var done: [String: LedgerEntry] = [:]
        var partial: [String: String] = [:]   // xid -> part file name
    }
    private var stored = Stored()
    private let url: URL

    public init(url: URL) {
        self.url = url
        if let d = try? Data(contentsOf: url) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            if let s = try? dec.decode(Stored.self, from: d) { stored = s }
        }
    }

    public func has(_ xid: String) -> Bool { stored.done[xid] != nil }
    public func entry(_ xid: String) -> LedgerEntry? { stored.done[xid] }
    public func latest(kind: String) -> LedgerEntry? {
        stored.done.values.filter { $0.kind == kind }.max { $0.savedAt < $1.savedAt }
    }
    /// Newest first.
    public func recent(limit: Int) -> [LedgerEntry] {
        Array(stored.done.values.filter { !isLibraryTransfer($0.xid) }.sorted { $0.savedAt > $1.savedAt }.prefix(limit))
    }
    public func record(_ e: LedgerEntry) { stored.done[e.xid] = e; stored.partial[e.xid] = nil; save() }
    public func partialName(_ xid: String) -> String? { stored.partial[xid] }
    public func setPartial(_ xid: String, name: String?) { stored.partial[xid] = name; save() }
    public func removeAll() { stored = Stored(); save() }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? enc.encode(stored) { try? d.write(to: url, options: .atomic) }
    }
}

public enum FileNaming {
    /// Strips path components and control characters.
    public static func sanitize(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "\\", with: "/")
        s = String(s.split(separator: "/").last ?? "file")
        s = s.filter { !$0.isNewline && $0.asciiValue.map { $0 >= 32 } ?? true }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s == "." || s == ".." { return "file" }
        return s
    }

    /// `name`, or `name (2).ext`, `name (3).ext`... whichever doesn't exist in `dir`.
    public static func uniqueURL(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        let first = dir.appendingPathComponent(name)
        if !fm.fileExists(atPath: first.path) { return first }
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        var i = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            let u = dir.appendingPathComponent(candidate)
            if !fm.fileExists(atPath: u.path) { return u }
            i += 1
        }
    }
}

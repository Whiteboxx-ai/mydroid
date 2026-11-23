import Foundation
import UniformTypeIdentifiers

// Mac files on the phone (PROTOCOL.md section 9), the Mac side: which folders are shared, path resolution with strict
// confinement, directory listing, and the `fs.*` request handler. No AppKit here; thumbnails and Spotlight come in through
// protocols implemented by the app.

/// A shared folder, resolved to a real directory.
public struct ShareRoot: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var url: URL
    public var writable: Bool
    public init(id: String, name: String, url: URL, writable: Bool) { self.id = id; self.name = name; self.url = url; self.writable = writable }
}

public struct FileShareConfig: Sendable, Equatable {
    public var enabled: Bool
    public var roots: [ShareRoot]
    public init(enabled: Bool = false, roots: [ShareRoot] = []) { self.enabled = enabled; self.roots = roots }
}

public enum FileShareError: String, Error, Sendable {
    case notFound = "not_found"
    case denied
    case off
}

// MARK: Path resolution

/// Resolves paths from the phone inside one root and refuses anything that would leave it.
public struct SharePath: Sendable {
    /// The root with every symlink resolved (`realpath`).
    public let root: String

    public init?(root: URL) {
        guard let r = SharePath.realpath(root.path) else { return nil }
        self.root = r
    }

    static func realpath(_ path: String) -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        guard Darwin.realpath(path, &buf) != nil else { return nil }
        return String(cString: buf)
    }

    /// Splits a relative path from the phone. Rejects absolute paths, `..`, `.`, empty and hidden components, and NUL.
    /// One trailing slash is tolerated. `""` is the root itself.
    public static func components(_ relative: String) throws -> [String] {
        if relative.isEmpty { return [] }
        if relative.hasPrefix("/") || relative.contains("\0") { throw FileShareError.denied }
        var parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" { parts.removeLast() }
        for p in parts {
            if p.isEmpty || p == "." || p == ".." || p.hasPrefix(".") { throw FileShareError.denied }
        }
        return parts
    }

    /// The real path of an existing file or folder under the root. Throws `.denied` for anything that resolves outside the root
    /// (a symlink pointing out, for example) or into a hidden folder, and `.notFound` when nothing is there.
    public func resolve(_ relative: String) throws -> URL {
        let parts = try Self.components(relative)
        let joined = parts.isEmpty ? root : root + "/" + parts.joined(separator: "/")
        guard let real = Self.realpath(joined) else {
            // Could be missing, or a symlink whose target is missing.
            throw FileManager.default.fileExists(atPath: joined) ? FileShareError.denied : FileShareError.notFound
        }
        guard let rel = relativePath(ofRealPath: real) else { throw FileShareError.denied }
        if rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { throw FileShareError.denied }
        return URL(fileURLWithPath: real)
    }

    /// The path relative to the root, or nil when `real` isn't inside it.
    public func relativePath(ofRealPath real: String) -> String? {
        if real == root { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard real.hasPrefix(prefix) else { return nil }
        return String(real.dropFirst(prefix.count))
    }
}

public enum ShareMime {
    public static func forFile(named name: String) -> String {
        UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
    public static let directory = "inode/directory"
}

// MARK: Listing

public struct ShareEntry: Sendable, Equatable {
    public var name: String
    public var dir: Bool
    public var size: Int64
    public var mtime: Int64
    public var mime: String

    var json: [String: Any] { ["name": name, "dir": dir, "size": size, "mtime": mtime, "mime": mime] }
}

public enum ShareListing {
    /// Keeps a listing comfortably under the 1 MiB frame limit (the protocol has no paging).
    public static let maxBytes = 700_000
    public static let maxEntries = 5000

    /// The visible entries of a folder: folders first, then names in Finder order. Hidden files and symlinks that leave the root are skipped.
    public static func list(dir: URL, in path: SharePath) throws -> [ShareEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        let urls: [URL]
        do { urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) }
        catch { throw FileShareError.denied }
        var out: [ShareEntry] = []
        for u in urls {
            let name = u.lastPathComponent
            guard !name.hasPrefix(".") else { continue }
            var target = u
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.isSymbolicLink == true {
                // A link is shown only when it points somewhere inside the root.
                guard let real = SharePath.realpath(u.path), let rel = path.relativePath(ofRealPath: real),
                      !rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
                target = URL(fileURLWithPath: real)
            }
            let tv = (target == u) ? v : (try? target.resourceValues(forKeys: Set(keys)))
            let isDir = tv?.isDirectory ?? false
            let mtime = Int64(((tv?.contentModificationDate ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970 * 1000).rounded())
            out.append(ShareEntry(name: name, dir: isDir, size: isDir ? 0 : Int64(tv?.fileSize ?? 0), mtime: mtime,
                                  mime: isDir ? ShareMime.directory : ShareMime.forFile(named: name)))
        }
        out.sort { a, b in
            if a.dir != b.dir { return a.dir }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        var bytes = 0
        var capped: [ShareEntry] = []
        for e in out {
            bytes += e.name.utf8.count + 96
            if bytes > maxBytes || capped.count >= maxEntries { break }
            capped.append(e)
        }
        return capped
    }
}

// MARK: Providers (implemented by the app)

public protocol FileThumbnailProvider: AnyObject {
    /// A JPEG of about `maxPixel` on the long edge, or nil. `completion` may be called on any thread.
    func thumbnail(for url: URL, maxPixel: Int, completion: @escaping (Data?) -> Void)
}

public protocol FileSearchProvider: AnyObject {
    /// Files whose name matches `query`, best first, under any of `roots`. `completion` may be called on any thread.
    func search(query: String, in roots: [URL], limit: Int, completion: @escaping ([URL]) -> Void)
    /// Recently used files under `roots`, newest first.
    func recent(in roots: [URL], limit: Int, completion: @escaping ([URL]) -> Void)
}

// MARK: Settings (persisted by the app)

public struct FileShareRootSetting: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var path: String
    public var bookmark: Data?
    public var writable: Bool

    public init(id: String, name: String, url: URL, writable: Bool = false) {
        self.id = id; self.name = name; self.path = url.path; self.writable = writable
        self.bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The folder now: the bookmark follows it if it was moved or renamed, the stored path is the fallback.
    public func resolve() -> (url: URL, stale: Bool)? {
        var isDir: ObjCBool = false
        if let bookmark {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                return (u, stale || u.path != path)
            }
        }
        let u = URL(fileURLWithPath: path, isDirectory: true)
        if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue { return (u, false) }
        return nil
    }
}

public struct FileShareSettings: Codable, Equatable, Sendable {
    public var enabled = true
    public var roots: [FileShareRootSetting]

    public init(enabled: Bool = true, roots: [FileShareRootSetting]) { self.enabled = enabled; self.roots = roots }

    /// Desktop, Documents and Downloads, read-only.
    public static func standard(desktop: URL, documents: URL, downloads: URL) -> FileShareSettings {
        FileShareSettings(roots: [
            FileShareRootSetting(id: "desktop", name: "Desktop", url: desktop),
            FileShareRootSetting(id: "documents", name: "Documents", url: documents),
            FileShareRootSetting(id: "downloads", name: "Downloads", url: downloads),
        ])
    }

    /// The roots that still exist, and refreshed bookmarks for the ones that moved.
    public func resolved() -> (config: FileShareConfig, updated: FileShareSettings?) {
        var roots: [ShareRoot] = []
        var changed = self
        var didChange = false
        var seen = Set<String>()
        for (i, r) in self.roots.enumerated() {
            guard let (url, stale) = r.resolve(), seen.insert(r.id).inserted else { continue }
            roots.append(ShareRoot(id: r.id, name: r.name, url: url, writable: r.writable))
            if stale {
                var n = FileShareRootSetting(id: r.id, name: r.name, url: url, writable: r.writable)
                n.name = r.name
                changed.roots[i] = n
                didChange = true
            }
        }
        return (FileShareConfig(enabled: enabled, roots: roots), didChange ? changed : nil)
    }

    /// Adds a folder unless it is already shared. Returns the new entry's id.
    @discardableResult
    public mutating func add(_ url: URL) -> String? {
        let real = SharePath.realpath(url.path) ?? url.path
        if roots.contains(where: { (SharePath.realpath($0.path) ?? $0.path) == real }) { return nil }
        let base = url.lastPathComponent.isEmpty ? "Folder" : url.lastPathComponent
        var name = base
        var n = 2
        while roots.contains(where: { $0.name == name }) { name = "\(base) \(n)"; n += 1 }
        let id = UUID().uuidString.lowercased()
        roots.append(FileShareRootSetting(id: id, name: name, url: url))
        return id
    }
}

// MARK: The service

/// Handles the `fs.*` requests of PROTOCOL.md section 9. Runs on the Hub's queue.
public final class FileShareService {
    public struct PendingPut {
        public let rootId: String
        public let folder: String
        public let name: String
        let expires: Date
    }

    private let queue: DispatchQueue
    private let macName: String
    private let send: (Message) -> Void
    private let offer: (URL, String) -> Bool
    private let log: (String) -> Void

    public private(set) var config = FileShareConfig()
    public weak var thumbnails: FileThumbnailProvider?
    public weak var search: FileSearchProvider?

    private var puts: [String: PendingPut] = [:]
    private var thumbQueue: [() -> Void] = []
    private var thumbsInFlight = 0
    static let maxThumbsInFlight = 6
    static let putLifetime: TimeInterval = 60
    public static let thumbnailPixels = 256
    static let maxThumbnailBytes = 800_000
    public static let maxSearchResults = 50
    public static let maxRecentResults = 30

    public init(queue: DispatchQueue, macName: String, send: @escaping (Message) -> Void, offer: @escaping (URL, String) -> Bool,
                log: @escaping (String) -> Void = { _ in }) {
        self.queue = queue; self.macName = macName; self.send = send; self.offer = offer; self.log = log
    }

    public func update(_ c: FileShareConfig) {
        guard c != config else { return }
        config = c
        puts.removeAll()          // an announced upload doesn't survive a change of what is shared
    }

    public func connectionClosed() { puts.removeAll(); thumbQueue.removeAll() }

    static func handles(_ type: String) -> Bool { type.hasPrefix("fs.") }

    /// Returns true when `m` was an `fs.*` request (and so has been dealt with).
    @discardableResult
    public func handle(_ m: Message) -> Bool {
        guard Self.handles(m.type) else { return false }
        guard let req = WireID(any: m.fields["req"]) else { log("fs: request without req"); return true }
        switch m.type {
        case "fs.roots": roots(req)
        case "fs.list": list(req, m)
        case "fs.thumb": thumb(req, m)
        case "fs.get": get(req, m)
        case "fs.put": put(req, m)
        case "fs.search": searchFiles(req, m, recent: false)
        case "fs.recent": searchFiles(req, m, recent: true)
        default: break    // fs.*.result and fs.error are ours to send, never to receive
        }
        return true
    }

    // MARK: Requests

    private func roots(_ req: WireID) {
        let list: [[String: Any]] = config.enabled ? config.roots.map { ["id": $0.id, "name": $0.name, "writable": $0.writable] } : []
        send(Message("fs.roots.result", ["req": req.json, "roots": list, "macName": macName]))
    }

    private func resolve(_ m: Message, folder key: String = "path") throws -> (root: ShareRoot, path: SharePath, url: URL, relative: String) {
        guard config.enabled else { throw FileShareError.off }
        guard let rootId = m.string("root"), let root = config.roots.first(where: { $0.id == rootId }) else { throw FileShareError.notFound }
        guard let sp = SharePath(root: root.url) else { throw FileShareError.notFound }
        let rel = m.string(key) ?? ""
        return (root, sp, try sp.resolve(rel), rel)
    }

    private func fail(_ req: WireID, _ e: FileShareError) { send(Message("fs.error", ["req": req.json, "error": e.rawValue])) }

    private func list(_ req: WireID, _ m: Message) {
        do {
            let r = try resolve(m)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: r.url.path, isDirectory: &isDir), isDir.boolValue else { throw FileShareError.notFound }
            let items = try ShareListing.list(dir: r.url, in: r.path)
            send(Message("fs.list.result", ["req": req.json, "items": items.map(\.json)]))
        } catch {
            send(Message("fs.list.result", ["req": req.json, "error": ((error as? FileShareError) ?? .denied).rawValue]))
        }
    }

    private func thumb(_ req: WireID, _ m: Message) {
        func no() { send(Message("fs.thumb.result", ["req": req.json, "ok": false])) }
        guard let r = try? resolve(m), isRegularFile(r.url), let provider = thumbnails else { return no() }
        let work = { [weak self] in
            guard let self else { return }
            provider.thumbnail(for: r.url, maxPixel: Self.thumbnailPixels) { data in
                self.queue.async {
                    self.thumbsInFlight -= 1
                    if let data, !data.isEmpty, data.count <= Self.maxThumbnailBytes {
                        self.send(Message("fs.thumb.result", ["req": req.json, "ok": true], payload: data))
                    } else { no() }
                    self.nextThumb()
                }
            }
        }
        thumbQueue.append(work)
        nextThumb()
    }

    private func nextThumb() {
        while thumbsInFlight < Self.maxThumbsInFlight, !thumbQueue.isEmpty {
            thumbsInFlight += 1
            thumbQueue.removeFirst()()
        }
    }

    /// A file or folder the phone asked to open, inside the shared roots and nowhere else (the same rules as `fs.get`).
    public func resolveForOpen(root: String?, path: String?, regularFileOnly: Bool) throws -> URL {
        guard config.enabled else { throw FileShareError.off }
        guard let root, let r = config.roots.first(where: { $0.id == root }), let sp = SharePath(root: r.url) else { throw FileShareError.notFound }
        let url = try sp.resolve(path ?? "")
        if regularFileOnly && !isRegularFile(url) { throw FileShareError.notFound }
        return url
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    private func get(_ req: WireID, _ m: Message) {
        do {
            let r = try resolve(m)
            guard isRegularFile(r.url) else { throw FileShareError.notFound }
            guard offer(r.url, "fs:" + req.text) else { throw FileShareError.notFound }
        } catch {
            fail(req, (error as? FileShareError) ?? .denied)
        }
    }

    private func put(_ req: WireID, _ m: Message) {
        do {
            let r = try resolve(m)
            guard r.root.writable else { throw FileShareError.denied }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: r.url.path, isDirectory: &isDir), isDir.boolValue else { throw FileShareError.notFound }
            guard let rawName = m.string("name"), m.int("size").map({ $0 >= 0 }) ?? false else { throw FileShareError.denied }
            let name = FileNaming.sanitize(rawName)
            guard !name.hasPrefix(".") else { throw FileShareError.denied }
            let now = Date()
            puts = puts.filter { $0.value.expires > now }
            puts["fsput:" + req.text] = PendingPut(rootId: r.root.id, folder: r.relative, name: name, expires: now.addingTimeInterval(Self.putLifetime))
            send(Message("fs.put.ready", ["req": req.json]))
        } catch {
            fail(req, (error as? FileShareError) ?? .denied)
        }
    }

    /// Called for the phone's `xfer.offer xid:"fsput:<req>"`. Checks the settings again and returns the folder to save into.
    /// A put is good for one offer.
    public func consumePut(xid: String) -> (dir: URL, name: String)? {
        guard let p = puts.removeValue(forKey: xid), p.expires > Date(), config.enabled,
              let root = config.roots.first(where: { $0.id == p.rootId }), root.writable,
              let sp = SharePath(root: root.url), let dir = try? sp.resolve(p.folder) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return (dir, p.name)
    }

    private func searchFiles(_ req: WireID, _ m: Message, recent: Bool) {
        guard config.enabled else { return fail(req, .off) }
        let query = (m.string("query") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !recent && query.isEmpty { return send(Message("fs.search.result", ["req": req.json, "items": [[String: Any]]()])) }
        let limit = recent ? Self.maxRecentResults : Self.maxSearchResults
        let cfg = config
        let spaths = cfg.roots.compactMap { r in SharePath(root: r.url).map { (r, $0) } }
        guard let provider = search, !spaths.isEmpty else {
            return send(Message("fs.search.result", ["req": req.json, "items": [[String: Any]]()]))
        }
        let done: ([URL]) -> Void = { [weak self] urls in
            guard let self else { return }
            self.queue.async {
                let items = Self.hits(urls, roots: spaths, limit: limit)
                self.send(Message("fs.search.result", ["req": req.json, "items": items]))
            }
        }
        let roots = cfg.roots.map(\.url)
        if recent { provider.recent(in: roots, limit: limit * 4, completion: done) }
        else { provider.search(query: String(query.prefix(200)), in: roots, limit: limit * 4, completion: done) }
    }

    /// Turns Spotlight's file URLs into protocol items, dropping anything outside the shared roots, hidden, or gone.
    static func hits(_ urls: [URL], roots: [(ShareRoot, SharePath)], limit: Int) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var seen = Set<String>()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        for u in urls {
            guard out.count < limit, let real = SharePath.realpath(u.path), seen.insert(real).inserted else { continue }
            guard let (root, sp, rel) = roots.lazy.compactMap({ r, s in s.relativePath(ofRealPath: real).map { (r, s, $0) } }).first,
                  !rel.isEmpty, !rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
            _ = sp
            let ru = URL(fileURLWithPath: real)
            let v = try? ru.resourceValues(forKeys: keys)
            let isDir = v?.isDirectory ?? false
            let name = ru.lastPathComponent
            out.append(["root": root.id, "path": rel, "name": name, "dir": isDir, "size": isDir ? 0 : Int64(v?.fileSize ?? 0),
                        "mtime": Int64(((v?.contentModificationDate ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970 * 1000).rounded()),
                        "mime": isDir ? ShareMime.directory : ShareMime.forFile(named: name)])
        }
        return out
    }
}

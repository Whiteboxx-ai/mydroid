import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import MydroidCore

/// One thumbnail's image, observed only by the cell that shows it.
@MainActor @Observable
final class ThumbSlot {
    var image: NSImage?
    var failed = false
}

enum DownloadState: Equatable {
    case downloading(Double)
    case ready(URL)
    case failed(String)
}

struct AlbumState: Equatable {
    var items: [PhotoItem] = []
    var more = true
    var loading = false
    var loaded = false
    var error: String?
    /// Set once a page older than the first has been requested; head refreshes then leave `more` alone.
    var pagedOnce = false
}

struct PhotoMonth: Identifiable {
    var id: String
    var title: String
    var items: [PhotoItem]
}

/// Browsing the phone's photo library (PROTOCOL.md 7.7): paged metadata, lazy thumbnails cached in memory and
/// on disk, originals downloaded into the cache on demand.
@MainActor @Observable
final class PhotosModel {
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored let hub: Hub

    var album: PhotoAlbum = .all
    var albums: [PhotoAlbum: AlbumState] = [:]
    var selection: Set<String> = []
    var anchor: String?
    var previewID: String?
    var downloads: [String: DownloadState] = [:]
    var thumbSize: Double = 128 { didSet { UserDefaults.standard.set(thumbSize, forKey: "photoThumbSize") } }
    var saving: String?
    var lastRefresh: Date?
    /// The phone answered `photos.page` with `error:"permission"`.
    var permissionDenied = false

    // Thumbnails
    @ObservationIgnored private let memory: NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.countLimit = 600; return c }()
    @ObservationIgnored private let slots = NSMapTable<NSString, ThumbSlot>(keyOptions: .strongMemory, valueOptions: .weakMemory)
    @ObservationIgnored private var wanted: [WireID] = []
    @ObservationIgnored private var inflight: [String: Date] = [:]
    @ObservationIgnored private var attempts: [String: Int] = [:]
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private let thumbsRoot: URL
    @ObservationIgnored private var thumbsDir: URL
    @ObservationIgnored private var listTimeouts: [PhotoAlbum: Task<Void, Never>] = [:]

    // Downloads
    @ObservationIgnored private var waiters: [String: [CheckedContinuation<URL, Error>]] = [:]
    @ObservationIgnored private var queued: [PhotoItem] = []
    @ObservationIgnored private var active: [String: (item: PhotoItem, lastProgress: Date)] = [:]
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var itemsByID: [String: PhotoItem] = [:]
    private static let maxConcurrentDownloads = 2

    init(hub: Hub, caches: URL) {
        self.hub = hub
        thumbsRoot = caches.appendingPathComponent("Thumbs", isDirectory: true)
        thumbsDir = thumbsRoot.appendingPathComponent("default", isDirectory: true)
        let saved = UserDefaults.standard.double(forKey: "photoThumbSize")
        if saved >= 80 { thumbSize = min(saved, 260) }
        pruneCaches()
    }

    /// Thumbnails are cached per pairing, so a different phone never shows the old phone's pictures.
    func setPairing(_ key: String?) {
        thumbsDir = thumbsRoot.appendingPathComponent(key ?? "default", isDirectory: true)
    }

    private func pruneCaches() {
        let root = thumbsRoot, lib = hub.libraryFile(id: "x", name: "x").deletingLastPathComponent().deletingLastPathComponent()
        Task.detached(priority: .background) { Self.prune([(root, 30), (lib, 3)]) }
    }

    /// Cache files older than the given number of days go.
    nonisolated private static func prune(_ dirs: [(URL, Double)]) {
        let fm = FileManager.default
        for (dir, days) in dirs {
            guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { continue }
            let cutoff = Date().addingTimeInterval(-days * 86400)
            for case let u as URL in e {
                let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                if v?.isRegularFile == true, let d = v?.contentModificationDate, d < cutoff { try? fm.removeItem(at: u) }
            }
        }
    }

    // MARK: Library pages

    var current: AlbumState { albums[album] ?? AlbumState() }
    var items: [PhotoItem] { current.items }

    func item(_ id: String) -> PhotoItem? { itemsByID[id] ?? items.first { $0.id.text == id } }

    func activate() {
        guard app?.state.link == .connected else { return }
        if !current.loaded && !current.loading { loadFirst() }
    }

    func setAlbum(_ a: PhotoAlbum) {
        guard a != album else { return }
        album = a
        selection = []
        activate()
    }

    func refresh() {
        guard app?.state.link == .connected else { return }
        loadFirst(force: true)
    }

    private func loadFirst(force: Bool = false) {
        var s = albums[album] ?? AlbumState()
        guard !s.loading else { return }
        s.loading = true; s.error = nil
        albums[album] = s
        hub.requestPhotos(limit: 60, before: nil, album: album)
        armTimeout(album)
    }

    func loadMoreIfNeeded(after item: PhotoItem) {
        let s = current
        guard s.more, !s.loading, let last = s.items.last, last.id == item.id || s.items.suffix(24).contains(where: { $0.id == item.id }),
              app?.state.link == .connected else { return }
        var n = s; n.loading = true
        albums[album] = n
        hub.requestPhotos(limit: 60, before: last.taken, album: album)
        armTimeout(album)
    }

    private func armTimeout(_ a: PhotoAlbum) {
        listTimeouts[a]?.cancel()
        listTimeouts[a] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, var s = self.albums[a], s.loading else { return }
            s.loading = false
            if !s.loaded { s.error = "Your phone didn't answer." }
            self.albums[a] = s
        }
    }

    func handle(_ e: HubEvent) {
        switch e {
        case let .photosPage(p): applyPage(p)
        case let .photoThumb(id, jpeg): thumbArrived(id, jpeg)
        case let .libraryProgress(id, done, total):
            if active[id] != nil {
                active[id]?.lastProgress = Date()
                downloads[id] = .downloading(total > 0 ? Double(done) / Double(total) : 0)
            }
        case let .libraryReady(id, url): downloadFinished(id, .success(url))
        case let .libraryFailed(id, error): downloadFinished(id, .failure(DownloadError.failed(error)))
        case .sessionClosed:
            for a in PhotoAlbum.allCases { if var s = albums[a], s.loading { s.loading = false; albums[a] = s } }
            inflight.removeAll()
            for (id, _) in active { downloadFinished(id, .failure(DownloadError.failed("Your phone disconnected"))) }
            queued.removeAll()
        case .sessionReady:
            if albums[album]?.loaded == true { refresh() } else { activate() }
            reflush()
        default: break
        }
    }

    private func applyPage(_ p: PhotosPage) {
        listTimeouts[p.album]?.cancel()
        var s = albums[p.album] ?? AlbumState()
        if p.error == "permission" {
            permissionDenied = true
            s.loading = false
            albums[p.album] = s
            return
        }
        permissionDenied = false
        var map: [WireID: PhotoItem] = [:]
        for i in s.items { map[i.id] = i }
        for i in p.items { map[i.id] = i; itemsByID[i.id.text] = i }
        s.items = map.values.sorted { $0.taken > $1.taken }
        s.loading = false
        s.loaded = true
        s.error = nil
        if p.before != nil || !s.pagedOnce { s.more = p.more }
        if p.before != nil { s.pagedOnce = true }
        albums[p.album] = s
        lastRefresh = Date()
    }

    /// Month sections, newest first.
    func months(of list: [PhotoItem]) -> [PhotoMonth] {
        var out: [PhotoMonth] = []
        let cal = Calendar.current
        for i in list {
            let c = cal.dateComponents([.year, .month], from: i.taken)
            let id = "\(c.year ?? 0)-\(c.month ?? 0)"
            if let last = out.indices.last, out[last].id == id { out[last].items.append(i) }
            else { out.append(PhotoMonth(id: id, title: i.taken.formatted(.dateTime.month(.wide).year()), items: [i])) }
        }
        return out
    }

    // MARK: Selection

    func click(_ item: PhotoItem, command: Bool, shift: Bool) {
        let id = item.id.text
        if shift, let a = anchor, let ai = items.firstIndex(where: { $0.id.text == a }), let bi = items.firstIndex(where: { $0.id == item.id }) {
            selection = Set(items[min(ai, bi)...max(ai, bi)].map { $0.id.text })
        } else if command {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else {
            selection = [id]
            anchor = id
        }
    }

    func selectAll() { selection = Set(items.map { $0.id.text }) }

    var selectedItems: [PhotoItem] { items.filter { selection.contains($0.id.text) } }

    // MARK: Preview

    func openPreview(_ item: PhotoItem) {
        previewID = item.id.text
        selection = [item.id.text]
        ensureDownload(item)
    }

    func closePreview() { previewID = nil }

    func stepPreview(_ delta: Int) {
        guard let id = previewID, let i = items.firstIndex(where: { $0.id.text == id }) else { return }
        let n = i + delta
        guard items.indices.contains(n) else { return }
        openPreview(items[n])
        loadMoreIfNeeded(after: items[n])
    }

    func previewOrSelected() {
        if previewID != nil { closePreview() }
        else if let i = selectedItems.first ?? items.first { openPreview(i) }
    }

    // MARK: Thumbnails

    func slot(for item: PhotoItem) -> ThumbSlot {
        let key = item.id.text as NSString
        if let s = slots.object(forKey: key) { return s }
        let s = ThumbSlot()
        slots.setObject(s, forKey: key)
        itemsByID[item.id.text] = item
        if let img = memory.object(forKey: key) { s.image = img } else { load(item.id, into: s) }
        return s
    }

    func cachedThumb(_ id: String) -> NSImage? { memory.object(forKey: id as NSString) }

    /// Puts a thumbnail in the memory cache (used when one is already at hand, and by the off-screen renders).
    func cacheThumb(_ image: NSImage, id: String) { memory.setObject(image, forKey: id as NSString) }

    private func diskURL(_ id: String) -> URL { thumbsDir.appendingPathComponent(Hub.safeComponent(id) + ".jpg") }

    private func load(_ id: WireID, into slot: ThumbSlot) {
        let url = diskURL(id.text)
        Task { [weak self] in
            let img = await Task.detached(priority: .utility) { () -> NSImage? in
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return decodeImage(url: url, maxPixel: 400)
            }.value
            guard let self else { return }
            if let img {
                self.memory.setObject(img, forKey: id.text as NSString)
                slot.image = img
            } else if slot.image == nil, self.slots.object(forKey: id.text as NSString) === slot {
                self.want(id)
            }
        }
    }

    /// A cell scrolled away before its thumbnail was asked for.
    func unwant(_ item: PhotoItem) { wanted.removeAll { $0 == item.id } }

    private func want(_ id: WireID) {
        guard inflight[id.text] == nil, !wanted.contains(id) else { return }
        wanted.append(id)
        reflush()
    }

    private func reflush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func flush() {
        guard app?.state.link == .connected else { return }
        let now = Date()
        for (id, at) in inflight where now.timeIntervalSince(at) > 15 {
            inflight[id] = nil
            attempts[id, default: 0] += 1
            if attempts[id]! >= 3 { slots.object(forKey: id as NSString)?.failed = true }
            else if slots.object(forKey: id as NSString) != nil { wanted.append(WireID(id, numeric: Int64(id) != nil)) }
        }
        let room = 60 - inflight.count
        guard room > 0, !wanted.isEmpty else { if !inflight.isEmpty { reflushLater() }; return }
        // Newest requests first: what the user just scrolled to.
        let take = Array(wanted.suffix(room).reversed())
        wanted.removeLast(min(room, wanted.count))
        for id in take { inflight[id.text] = now }
        hub.requestThumbs(ids: take)
        reflushLater()
    }

    private func reflushLater() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func thumbArrived(_ id: WireID, _ jpeg: Data) {
        inflight[id.text] = nil
        let key = id.text
        if jpeg.isEmpty {   // the phone couldn't make this one
            slots.object(forKey: key as NSString)?.failed = true
            if !wanted.isEmpty { reflush() }
            return
        }
        let url = diskURL(key)
        Task { [weak self] in
            let img = await Task.detached(priority: .utility) { () -> NSImage? in
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? jpeg.write(to: url, options: .atomic)
                return decodeImage(data: jpeg, maxPixel: 400)
            }.value
            guard let self else { return }
            if let img {
                self.memory.setObject(img, forKey: key as NSString)
                self.slots.object(forKey: key as NSString)?.image = img
            } else {
                self.slots.object(forKey: key as NSString)?.failed = true
            }
            if !self.wanted.isEmpty { self.reflush() }
        }
    }

    // MARK: Originals

    enum DownloadError: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case let .failed(m) = self { return m }; return nil }
    }

    func readyURL(_ item: PhotoItem) -> URL? {
        if case let .ready(u) = downloads[item.id.text], FileManager.default.fileExists(atPath: u.path) { return u }
        let u = hub.libraryFile(id: item.id, name: item.name)
        if FileManager.default.fileExists(atPath: u.path), case .none = active[item.id.text] {
            downloads[item.id.text] = .ready(u)
            return u
        }
        return nil
    }

    func ensureDownload(_ item: PhotoItem) {
        let id = item.id.text
        if readyURL(item) != nil || active[id] != nil || queued.contains(where: { $0.id == item.id }) { return }
        guard app?.state.link == .connected else { downloads[id] = .failed("Your phone isn't connected"); return }
        downloads[id] = .downloading(0)
        queued.append(item)
        pump()
    }

    private func pump() {
        while active.count < Self.maxConcurrentDownloads, !queued.isEmpty {
            let item = queued.removeFirst()
            active[item.id.text] = (item, Date())
            hub.downloadPhoto(id: item.id)
        }
        if !active.isEmpty && watchdog == nil {
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard let self else { return }
                    for (id, a) in self.active where Date().timeIntervalSince(a.lastProgress) > 40 {
                        self.downloadFinished(id, .failure(DownloadError.failed("Your phone didn't send the photo")))
                    }
                    if self.active.isEmpty { self.watchdog = nil; return }
                }
            }
        }
    }

    private func downloadFinished(_ id: String, _ r: Result<URL, Error>) {
        active[id] = nil
        switch r {
        case let .success(u): downloads[id] = .ready(u)
        case let .failure(e): downloads[id] = .failed(e.localizedDescription)
        }
        let list = waiters.removeValue(forKey: id) ?? []
        for w in list { w.resume(with: r) }
        pump()
    }

    /// The original, downloading it first if needed.
    func download(_ item: PhotoItem) async throws -> URL {
        if let u = readyURL(item) { return u }
        guard app?.state.link == .connected else { throw DownloadError.failed("Your phone isn't connected") }
        return try await withCheckedThrowingContinuation { c in
            waiters[item.id.text, default: []].append(c)
            if case .failed = downloads[item.id.text] { downloads[item.id.text] = nil }
            ensureDownload(item)
        }
    }

    // MARK: Save, copy, drag

    /// Copies the originals into the Mydroid pictures folder (and Apple Photos if that is on).
    func save(_ list: [PhotoItem]) {
        guard !list.isEmpty, let app else { return }
        guard app.state.link == .connected || list.allSatisfy({ readyURL($0) != nil }) else { app.flash("\(app.phoneName) isn't connected"); return }
        let label = app.photosFolderLabel
        Task {
            var saved = 0, already = 0, failed = 0
            for (n, item) in list.enumerated() {
                saving = list.count > 1 ? "Saving \(n + 1) of \(list.count)\u{2026}" : "Saving\u{2026}"
                do {
                    if hub.syncedPhoto(name: item.name, size: item.size) != nil { already += 1; continue }
                    let src = try await download(item)
                    let dir = app.photosDirectory
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let dest = FileNaming.uniqueURL(in: dir, name: item.name)
                    try FileManager.default.copyItem(at: src, to: dest)
                    try? FileManager.default.setAttributes([.modificationDate: item.taken], ofItemAtPath: dest.path)
                    if app.prefs.importToApplePhotos { Task { await PhotosImporter.add(dest) } }
                    saved += 1
                } catch { failed += 1 }
            }
            saving = nil
            var parts: [String] = []
            if saved > 0 { parts.append(saved == 1 ? "Saved to \(label)" : "Saved \(saved) photos to \(label)") }
            if already > 0 { parts.append(already == 1 ? "Already in \(label)" : "\(already) already in \(label)") }
            if failed > 0 { parts.append("Couldn't save \(failed)") }
            app.flash(parts.joined(separator: ". "))
        }
    }

    func copy(_ item: PhotoItem) {
        Task {
            do {
                let url = try await download(item)
                let pb = NSPasteboard.general
                pb.clearContents()
                let pbItem = NSPasteboardItem()
                if let data = try? Data(contentsOf: url) {
                    let type = UTType(filenameExtension: url.pathExtension) ?? .jpeg
                    pbItem.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
                }
                pbItem.setString(url.absoluteString, forType: .fileURL)
                pb.writeObjects([pbItem])
                app?.flash("Copied")
            } catch { app?.flash("Couldn't copy the photo") }
        }
    }

    /// A drag provider: the cached file when it is already here, otherwise a file promise that downloads on drop.
    func dragProvider(for item: PhotoItem) -> NSItemProvider {
        if let url = readyURL(item), let p = NSItemProvider(contentsOf: url) { return p }
        let p = NSItemProvider()
        p.suggestedName = item.name
        let type = UTType(mimeType: item.mime) ?? .jpeg
        p.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { [weak self] done in
            let progress = Progress(totalUnitCount: 1)
            Task { @MainActor in
                do {
                    guard let self else { throw DownloadError.failed("Mydroid isn't running") }
                    let url = try await self.download(item)
                    done(url, false, nil)
                } catch { done(nil, false, error) }
                progress.completedUnitCount = 1
            }
            return progress
        }
        return p
    }
}

func decodeImage(url: URL, maxPixel: Int) -> NSImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return thumbImage(src, maxPixel)
}

func decodeImage(data: Data, maxPixel: Int) -> NSImage? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return thumbImage(src, maxPixel)
}

private func thumbImage(_ src: CGImageSource, _ maxPixel: Int) -> NSImage? {
    let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                 kCGImageSourceCreateThumbnailWithTransform: true,
                                 kCGImageSourceShouldCacheImmediately: true,
                                 kCGImageSourceThumbnailMaxPixelSize: maxPixel]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

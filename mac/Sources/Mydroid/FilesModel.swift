import SwiftUI
import AppKit
import MydroidCore

struct FileEntry: Identifiable, Equatable {
    enum Direction { case received, sent }
    enum Phase: Equatable { case done, active(Double), failed(String) }
    var id: String
    var name: String
    var size: Int64
    var date: Date
    var direction: Direction
    var isPhoto: Bool
    var url: URL?
    var phase: Phase = .done
    var exists: Bool { url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
}

/// What was sent to the phone, kept so the Files list survives a restart.
struct SentRecord: Codable, Equatable {
    var xid: String
    var name: String
    var size: Int64
    var date: Date
    var path: String?
    var failed: String?
}

/// Transfers in both directions: photos synced automatically, files received, files sent.
@MainActor @Observable
final class FilesModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", photos = "Photos", files = "Files", sent = "Sent"
        var id: String { rawValue }
    }

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored let hub: Hub
    @ObservationIgnored private let sentURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var sources: [String: URL] = [:]

    var received: [SavedFile] = []
    var sent: [SentRecord] = []
    var active: [TransferProgress] = []
    var filter: Filter = .all
    var dropTargeted = false
    var loaded = false

    init(hub: Hub, support: URL) {
        self.hub = hub
        sentURL = support.appendingPathComponent("sent.json")
        if let d = try? Data(contentsOf: sentURL) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            sent = (try? dec.decode([SentRecord].self, from: d)) ?? []
        }
    }

    func activate() {
        var map: [String: SavedFile] = [:]
        for f in received { map[f.xid] = f }
        for f in hub.recentTransfers(limit: 300) { map[f.xid] = f }
        received = map.values.sorted { $0.savedAt > $1.savedAt }
        loaded = true
    }

    func handle(_ e: HubEvent) {
        switch e {
        case let .received(f):
            received.removeAll { $0.xid == f.xid }
            received.insert(f, at: 0)
            if received.count > 300 { received.removeLast(received.count - 300) }
        case let .sent(xid, name, skipped):
            let src = sources.removeValue(forKey: xid)
            let size = src.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.int64Value } ?? 0
            record(SentRecord(xid: xid, name: name, size: size, date: Date(), path: src?.path, failed: nil))
            _ = skipped
        case let .sendFailed(xid, name, error):
            let src = sources.removeValue(forKey: xid)
            record(SentRecord(xid: xid, name: name, size: 0, date: Date(), path: src?.path, failed: error))
        default: break
        }
    }

    func track(xid: String, url: URL) { sources[xid] = url }

    private func record(_ r: SentRecord) {
        sent.removeAll { $0.xid == r.xid }
        sent.insert(r, at: 0)
        if sent.count > 200 { sent.removeLast(sent.count - 200) }
        saveTask?.cancel()
        let snap = sent, url = sentURL
        saveTask = Task.detached {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            if let d = try? enc.encode(snap) { try? d.write(to: url, options: .atomic) }
        }
    }

    func sync(transfers: [TransferProgress]) { if transfers != active { active = transfers } }

    /// Newest first, with in-flight transfers on top.
    var entries: [FileEntry] {
        var out: [FileEntry] = active.map {
            FileEntry(id: "active-" + $0.xid, name: $0.name, size: $0.total, date: Date(), direction: $0.outgoing ? .sent : .received,
                      isPhoto: $0.kind == "photo", url: nil, phase: .active($0.fraction))
        }
        let activeNames = Set(active.map(\.xid))
        for f in received where !activeNames.contains(f.xid) {
            out.append(FileEntry(id: f.xid, name: f.name, size: f.size, date: f.taken ?? f.savedAt, direction: .received,
                                 isPhoto: f.kind == "photo", url: f.url))
        }
        for s in sent where !activeNames.contains(s.xid) {
            out.append(FileEntry(id: s.xid, name: s.name, size: s.size, date: s.date, direction: .sent, isPhoto: false,
                                 url: s.path.map { URL(fileURLWithPath: $0) }, phase: s.failed.map { .failed($0) } ?? .done))
        }
        let head = out.prefix { if case .active = $0.phase { return true } else { return false } }.count
        let rest = out.dropFirst(head).sorted { $0.date > $1.date }
        let all = Array(out.prefix(head)) + rest
        switch filter {
        case .all: return all
        case .photos: return all.filter { $0.isPhoto && $0.direction == .received }
        case .files: return all.filter { !$0.isPhoto && $0.direction == .received }
        case .sent: return all.filter { $0.direction == .sent }
        }
    }

    func send(_ urls: [URL]) {
        guard let app else { return }
        guard app.state.link == .connected else { app.flash("\(app.phoneName) isn't connected"); return }
        for u in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            if let xid = hub.offerFile(u) { track(xid: xid, url: u) }
        }
    }
}

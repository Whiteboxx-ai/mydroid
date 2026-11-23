import Foundation
import UniformTypeIdentifiers

/// What the UI needs to ask the user about a Quick Share request.
public struct QuickShareIncoming: Sendable, Equatable, Identifiable {
    public var id: String
    public var sender: String
    public var deviceType: QSDeviceType
    public var pin: String
    public var fileCount: Int
    public var linkCount: Int
    public var textCount: Int
    public var totalBytes: Int64
    /// The first file's name, for the banner.
    public var firstFileName: String?
    public var expires: Date

    /// "a photo.jpg", "3 files", "a link", "some text"...
    public var summary: String {
        var parts: [String] = []
        if fileCount == 1, let n = firstFileName { parts.append(n) }
        else if fileCount > 1 { parts.append("\(fileCount) files") }
        if linkCount == 1 { parts.append("a link") } else if linkCount > 1 { parts.append("\(linkCount) links") }
        if textCount > 0 { parts.append("some text") }
        return parts.joined(separator: " and ")
    }
}

public struct QuickShareDone: Sendable, Equatable {
    public var id: String
    public var sender: String
    public var files: [SavedFile]
}

extension Hub {
    // MARK: Settings and lifecycle

    /// Turns Quick Share receiving on or off, and chooses when. Until this is called (the test server never does) nothing is advertised.
    public func setQuickShare(_ s: QuickShareSettings) {
        queue.async {
            self.qsConfigured = true
            self.qsSettings = s
            if s.others == .never { self.rejectPendingQuickShare() }
            self.reconcileQuickShare(dropConnections: s.visibility == .off)
        }
    }

    /// Starts or stops advertising to match the setting, the phone's connection and the Hub's own lifecycle.
    func reconcileQuickShare(dropConnections: Bool = false) {
        guard qsConfigured, started else { return }
        let want: Bool
        switch qsSettings.visibility {
        case .always: want = true
        case .phoneConnected: want = state.link == .connected
        case .off: want = false
        }
        if want {
            quickShare.start()
        } else {
            // A transfer already under way finishes even if the phone's link drops.
            if dropConnections { rejectPendingQuickShare() }
            quickShare.stop(dropConnections: dropConnections)
        }
    }

    func installQuickShare() {
        quickShare.log = { [unowned self] m in self.log(m) }
        quickShare.onRequest = { [weak self] req, respond in self?.queue.async { self?.quickShareRequest(req, respond) } }
        quickShare.onEvent = { [weak self] id, e in self?.queue.async { self?.quickShareEvent(id, e) } }
    }

    /// The user's answer to `.quickShareRequest`.
    public func quickShareRespond(id: String, accept: Bool) {
        queue.async {
            guard let respond = self.qsPending.removeValue(forKey: id) else { return }
            respond(accept ? .accept(destination: self.quickShareDestination()) : .reject)
            self.emit(.quickShareRequestEnded(id: id))
        }
    }

    private func rejectPendingQuickShare() {
        for (id, respond) in qsPending { respond(.reject); emit(.quickShareRequestEnded(id: id)) }
        qsPending.removeAll()
    }

    // MARK: Requests

    /// Where each file goes: Downloads, or the Photos folder for images when the user chose that.
    private func quickShareDestination() -> (QSItem) -> URL {
        let downloads = downloadsDirectory, photos = photosDirectory, imagesToPhotos = qsSettings.imagesToPhotosFolder
        return { item in imagesToPhotos && QuickShareFiles.isImage(item) ? photos : downloads }
    }

    private func quickShareRequest(_ req: QSRequest, _ respond: @escaping (QSDecision) -> Void) {
        qsRequests[req.id] = req
        let trusted = QuickShareTrust.isPairedPhone(
            senderName: req.senderName, senderHost: req.remoteHost,
            phoneName: state.phone?.name ?? cfg.identity.phoneName, phoneModel: state.phone?.model,
            phoneHost: state.phoneHost, connected: state.link == .connected)
        if trusted {
            log("quickshare: accepting from the paired phone (\(req.items.count) item(s))")
            return respond(.accept(destination: quickShareDestination()))
        }
        if qsSettings.others == .never || qsPending.count >= 3 {
            log("quickshare: declined a request from another device")
            return respond(.reject)
        }
        qsPending[req.id] = respond
        let files = req.files
        emit(.quickShareRequest(QuickShareIncoming(
            id: req.id, sender: req.senderName, deviceType: req.deviceType, pin: req.pin,
            fileCount: files.count, linkCount: req.items.filter { $0.kind == .url }.count, textCount: req.items.filter { $0.kind == .text }.count,
            totalBytes: req.totalFileBytes, firstFileName: files.first?.name, expires: Date().addingTimeInterval(30))))
    }

    // MARK: Events

    private func quickShareEvent(_ id: String, _ e: QSConnectionEvent) {
        let sender = qsRequests[id]?.senderName ?? "another device"
        switch e {
        case .decisionEnded:
            if qsPending.removeValue(forKey: id) != nil { emit(.quickShareRequestEnded(id: id)) }
        case let .progress(item, written):
            // Chunks are small; don't wake the UI for every one.
            let now = Date()
            if written < item.size, let last = qsLastProgress[id], now.timeIntervalSince(last) < 0.15 { return }
            qsLastProgress[id] = now
            let p = TransferProgress(xid: Self.quickShareXid(id, item), name: item.name, kind: "file", outgoing: false, done: written, total: item.size)
            if let i = state.transfers.firstIndex(where: { $0.xid == p.xid }) { state.transfers[i] = p } else { state.transfers.append(p) }
            publish()
        case let .file(item, url):
            let xid = Self.quickShareXid(id, item)
            let kind = qsSettings.imagesToPhotosFolder && QuickShareFiles.isImage(item) ? "photo" : "file"
            let entry = LedgerEntry(xid: xid, kind: kind, path: url.path, name: url.lastPathComponent, size: item.size, taken: nil, savedAt: Date())
            ledger.record(entry)
            let f = SavedFile(xid: xid, kind: kind, url: url, name: entry.name, size: item.size, taken: nil, savedAt: entry.savedAt)
            state.transfers.removeAll { $0.xid == xid }
            if kind == "photo" { state.latestPhoto = f }
            qsSaved[id, default: []].append(f)
            emit(.received(f))
            publish()
        case let .text(text, isURL):
            if isURL, let url = LinkPolicy.parse(text) { emit(.quickShareLink(url, from: sender)) }
            else { emit(.quickShareText(text, from: sender)) }
        case let .finished(reason):
            if qsPending.removeValue(forKey: id) != nil { emit(.quickShareRequestEnded(id: id)) }
            let prefix = "qs:\(id):"
            state.transfers.removeAll { $0.xid.hasPrefix(prefix) }
            let saved = qsSaved.removeValue(forKey: id) ?? []
            let hadRequest = qsRequests.removeValue(forKey: id) != nil
            qsLastProgress[id] = nil
            switch reason {
            case .completed:
                if !saved.isEmpty { emit(.quickShareDone(QuickShareDone(id: id, sender: sender, files: saved))) }
            case .senderCancelled:
                if hadRequest { emit(.quickShareFailed(from: sender, reason: "Cancelled")) }
            case let .failed(why):
                // Handshake failures from strangers poking the port are not worth a banner.
                if hadRequest { emit(.quickShareFailed(from: sender, reason: Self.friendly(why))) }
            case .rejected, .timedOut:
                break
            }
            publish()
        }
    }

    static func quickShareXid(_ id: String, _ item: QSItem) -> String { "qs:\(id):\(item.id)" }

    private static func friendly(_ why: String) -> String {
        switch why {
        case "not enough space": return "Not enough space"
        case "connection lost", "connection closed", "timed out": return "Connection dropped"
        default: return "Something went wrong"
        }
    }

    // MARK: Mac files on the phone (PROTOCOL.md section 9)

    /// The folders to share and whether sharing is on. Takes effect for the next request.
    public func setFileShare(_ c: FileShareConfig) { queue.async { self.fileShare.update(c) } }

    /// Thumbnails and Spotlight search come from the app (they need AppKit and a run loop).
    public func setFileShareProviders(thumbnails: FileThumbnailProvider?, search: FileSearchProvider?) {
        queue.async {
            self.fileShare.thumbnails = thumbnails
            self.fileShare.search = search
        }
    }

    /// `xfer.offer xid:"fsput:<req>"`: the phone is sending the file it announced with `fs.put`.
    func acceptFileSharePut(_ m: Message) {
        guard let xid = m.string("xid") else { return }
        guard let put = fileShare.consumePut(xid: xid) else {
            log("fs: refused an upload that wasn't allowed")
            send(Message("xfer.done", ["xid": xid, "ok": false, "error": "not allowed"]))
            return
        }
        fsPutDirectories[xid] = put.dir
        var fields = m.fields
        fields["name"] = put.name
        receiver.handle(Message("xfer.offer", fields, payload: m.payload))
        fsPutDirectories[xid] = nil
    }
}

public enum QuickShareFiles {
    public static func isImage(_ item: QSItem) -> Bool {
        if item.mime.lowercased().hasPrefix("image/") { return true }
        return UTType(filenameExtension: (item.name as NSString).pathExtension)?.conforms(to: .image) ?? false
    }
}

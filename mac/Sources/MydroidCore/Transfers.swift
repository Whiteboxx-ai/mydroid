import Foundation
import CryptoKit
import UniformTypeIdentifiers

public let transferChunkSize = 256 * 1024

/// Photo-library downloads (`photos.get`, PROTOCOL.md 7.7) use `xid` "lib:<id>". They are cache files:
/// never deduped, never recorded in the ledger, never resumed.
public func isLibraryTransfer(_ xid: String) -> Bool { xid.hasPrefix("lib:") }

/// The phone saving a file onto the Mac (`fs.put`, PROTOCOL.md section 9) uses `xid` "fsput:<req>". Like library downloads these
/// stay out of the dedupe ledger and are never skipped or resumed, but the file keeps its name (made unique) in its folder.
public func isFileSharePut(_ xid: String) -> Bool { xid.hasPrefix("fsput:") }

/// The Mac sending a shared file to the phone (`fs.get`) uses `xid` "fs:<req>".
public func isFileShareGet(_ xid: String) -> Bool { xid.hasPrefix("fs:") }

public enum OfferOutcome: Sendable, Equatable {
    case accept(offset: Int64)
    case skip
}

public enum ReceiverEvent: Sendable {
    case offer(xid: String, name: String, kind: String, size: Int64, outcome: OfferOutcome)
    case progress(xid: String, name: String, kind: String, written: Int64, size: Int64)
    case received(SavedFile)
    case failed(xid: String, error: String)
}

func sha256Hex(of url: URL, upTo limit: Int64? = nil) throws -> String {
    let h = try FileHandle(forReadingFrom: url)
    defer { try? h.close() }
    var hasher = SHA256()
    var remaining = limit ?? Int64.max
    while remaining > 0 {
        let n = Int(min(Int64(1 << 20), remaining))
        guard let d = try h.read(upToCount: n), !d.isEmpty else { break }
        hasher.update(data: d)
        remaining -= Int64(d.count)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Receiving side of PROTOCOL.md transfers: offer -> accept/skip -> chunks -> end -> done.
/// Partial files are kept as `<name>.part` so a dropped connection resumes where it stopped. With a staging
/// directory they live there, out of sight, and only the finished file lands in Downloads/Pictures.
public final class TransferReceiver {
    private final class Incoming {
        let xid, name, kind: String
        let ephemeral: Bool
        /// Not in the ledger: no dedupe, no resume.
        let untracked: Bool
        let size: Int64
        let taken: Date?
        let dir: URL
        let partURL: URL
        let handle: FileHandle
        var written: Int64
        init(xid: String, name: String, kind: String, ephemeral: Bool, untracked: Bool, size: Int64, taken: Date?, dir: URL, partURL: URL, handle: FileHandle, written: Int64) {
            self.xid = xid; self.name = name; self.kind = kind; self.ephemeral = ephemeral; self.untracked = untracked; self.size = size; self.taken = taken
            self.dir = dir; self.partURL = partURL; self.handle = handle; self.written = written
        }
    }

    private let ledger: TransferLedger
    private let directoryFor: (_ kind: String, _ name: String, _ xid: String) -> URL
    private let send: (Message) -> Void
    private let emit: (ReceiverEvent) -> Void
    private var active: [String: Incoming] = [:]
    private let staging: URL?

    public init(ledger: TransferLedger, directoryFor: @escaping (String, String, String) -> URL,
                send: @escaping (Message) -> Void, emit: @escaping (ReceiverEvent) -> Void, stagingDir: URL? = nil) {
        self.ledger = ledger; self.directoryFor = directoryFor; self.send = send; self.emit = emit; self.staging = stagingDir
        if let stagingDir { Self.prune(stagingDir) }
    }

    /// The phone gives up on a queued file after a day; anything older in staging will never resume.
    static func prune(_ dir: URL, olderThan age: TimeInterval = 48 * 3600) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for u in items {
            let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if m < cutoff { try? fm.removeItem(at: u) }
        }
    }

    public func handle(_ m: Message) {
        switch m.type {
        case "xfer.offer": offer(m)
        case "xfer.chunk": chunk(m)
        case "xfer.end": end(m)
        case "xfer.cancel": cancel(m)
        default: break
        }
    }

    public func isReceiving(_ xid: String) -> Bool { active[xid] != nil }

    /// Keep partial files, drop open handles.
    public func connectionClosed() {
        for i in active.values {
            try? i.handle.close()
            if i.untracked { try? FileManager.default.removeItem(at: i.partURL) }   // nothing will resume it
        }
        active.removeAll()
    }

    private func fail(_ xid: String, _ error: String) {
        if let i = active.removeValue(forKey: xid) {
            try? i.handle.close()
            if i.untracked { try? FileManager.default.removeItem(at: i.partURL) }
        }
        send(Message("xfer.done", ["xid": xid, "ok": false, "error": error]))
        emit(.failed(xid: xid, error: error))
    }

    private func offer(_ m: Message) {
        guard let xid = m.string("xid"), let rawName = m.string("name"), let size = m.int("size") else { return }
        let kind = m.string("kind") ?? "file"
        let name = FileNaming.sanitize(rawName)
        let ephemeral = isLibraryTransfer(xid)
        let untracked = ephemeral || isFileSharePut(xid)
        if !untracked, ledger.has(xid) {
            send(Message("xfer.skip", ["xid": xid]))
            emit(.offer(xid: xid, name: name, kind: kind, size: size, outcome: .skip))
            return
        }
        if let old = active.removeValue(forKey: xid) { try? old.handle.close() }
        let dir = directoryFor(kind, name, xid)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let partDir = ephemeral ? dir : (staging ?? dir)
            if partDir != dir { try fm.createDirectory(at: partDir, withIntermediateDirectories: true) }
            var partURL: URL
            var offset: Int64 = 0
            if ephemeral {
                partURL = dir.appendingPathComponent(name + ".part")
                try? fm.removeItem(at: partURL)
                fm.createFile(atPath: partURL.path, contents: nil)
            } else if !untracked, let pn = ledger.partialName(xid), fm.fileExists(atPath: partDir.appendingPathComponent(pn).path) {
                partURL = partDir.appendingPathComponent(pn)
                offset = (try fm.attributesOfItem(atPath: partURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                if offset > size { try fm.removeItem(at: partURL); fm.createFile(atPath: partURL.path, contents: nil); offset = 0 }
            } else {
                partURL = FileNaming.uniqueURL(in: partDir, name: name + ".part")
                fm.createFile(atPath: partURL.path, contents: nil)
                if !untracked { ledger.setPartial(xid, name: partURL.lastPathComponent) }
            }
            let h = try FileHandle(forUpdating: partURL)
            try h.seek(toOffset: UInt64(offset))
            let taken = m.int("taken").map { Date(timeIntervalSince1970: Double($0) / 1000) }
            active[xid] = Incoming(xid: xid, name: name, kind: kind, ephemeral: ephemeral, untracked: untracked, size: size, taken: taken, dir: dir,
                                   partURL: partURL, handle: h, written: offset)
            send(Message("xfer.accept", ["xid": xid, "offset": offset]))
            emit(.offer(xid: xid, name: name, kind: kind, size: size, outcome: .accept(offset: offset)))
            emit(.progress(xid: xid, name: name, kind: kind, written: offset, size: size))
        } catch {
            fail(xid, "Couldn't open destination: \(error.localizedDescription)")
        }
    }

    private func chunk(_ m: Message) {
        guard let xid = m.string("xid"), let i = active[xid] else { return }
        guard let off = m.int("offset"), off == i.written else { return fail(xid, "unexpected offset") }
        guard i.written + Int64(m.payload.count) <= i.size else { return fail(xid, "too much data") }
        do {
            try i.handle.write(contentsOf: m.payload)
            i.written += Int64(m.payload.count)
            emit(.progress(xid: xid, name: i.name, kind: i.kind, written: i.written, size: i.size))
        } catch {
            fail(xid, "write failed")
        }
    }

    private func end(_ m: Message) {
        guard let xid = m.string("xid"), let i = active.removeValue(forKey: xid) else { return }
        try? i.handle.synchronize()
        try? i.handle.close()
        let fm = FileManager.default
        guard i.written == i.size else {
            if i.untracked { try? fm.removeItem(at: i.partURL) }
            send(Message("xfer.done", ["xid": xid, "ok": false, "error": "size mismatch"]))
            emit(.failed(xid: xid, error: "size mismatch")); return
        }
        let expected = (m.string("sha256") ?? "").lowercased()
        let actual = (try? sha256Hex(of: i.partURL)) ?? ""
        guard expected == actual else {
            try? fm.removeItem(at: i.partURL)
            if !i.untracked { ledger.setPartial(xid, name: nil) }
            send(Message("xfer.done", ["xid": xid, "ok": false, "error": "sha256 mismatch"]))
            emit(.failed(xid: xid, error: "sha256 mismatch")); return
        }
        let final = i.ephemeral ? i.dir.appendingPathComponent(i.name) : FileNaming.uniqueURL(in: i.dir, name: i.name)
        do {
            if i.ephemeral { try? fm.removeItem(at: final) }
            try fm.moveItem(at: i.partURL, to: final)
            if let t = i.taken { try? fm.setAttributes([.modificationDate: t], ofItemAtPath: final.path) }
        } catch {
            send(Message("xfer.done", ["xid": xid, "ok": false, "error": "couldn't save file"]))
            emit(.failed(xid: xid, error: "couldn't save file")); return
        }
        let entry = LedgerEntry(xid: xid, kind: i.kind, path: final.path, name: final.lastPathComponent,
                                size: i.size, taken: i.taken, savedAt: Date())
        if !i.untracked { ledger.record(entry) }
        send(Message("xfer.done", ["xid": xid, "ok": true]))
        emit(.received(SavedFile(xid: xid, kind: i.kind, url: final, name: final.lastPathComponent,
                                 size: i.size, taken: i.taken, savedAt: entry.savedAt)))
    }

    private func cancel(_ m: Message) {
        guard let xid = m.string("xid") else { return }
        if let i = active.removeValue(forKey: xid) {
            try? i.handle.close()
            try? FileManager.default.removeItem(at: i.partURL)
            if !i.untracked { ledger.setPartial(xid, name: nil) }
            emit(.failed(xid: xid, error: "cancelled"))
        }
    }
}

public enum SenderEvent: Sendable {
    case progress(TransferProgress)
    case finished(xid: String, name: String, skipped: Bool)
    case failed(xid: String, name: String, error: String)
}

/// Sending side (Mac -> phone files).
public final class TransferSender {
    private final class Outgoing {
        let xid: String, name: String, size: Int64, url: URL
        var sha: String
        var offset: Int64 = 0
        var streaming = false
        init(xid: String, name: String, size: Int64, url: URL, sha: String) {
            self.xid = xid; self.name = name; self.size = size; self.url = url; self.sha = sha
        }
    }

    private let queue: DispatchQueue
    private let send: (Message, @escaping (Bool) -> Void) -> Void
    private let emit: (SenderEvent) -> Void
    private var active: [String: Outgoing] = [:]

    public init(queue: DispatchQueue, send: @escaping (Message, @escaping (Bool) -> Void) -> Void, emit: @escaping (SenderEvent) -> Void) {
        self.queue = queue; self.send = send; self.emit = emit
    }

    /// Hashes the file off-queue, then offers it. Returns the xid immediately.
    @discardableResult
    public func offer(file url: URL, xid: String = "file:" + UUID().uuidString.lowercased()) -> String? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value else { return nil }
        let name = url.lastPathComponent
        emit(.progress(TransferProgress(xid: xid, name: name, kind: "file", outgoing: true, done: 0, total: size)))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sha = try? sha256Hex(of: url)
            self?.queue.async {
                guard let self else { return }
                guard let sha else { self.emit(.failed(xid: xid, name: name, error: "Couldn't read the file")); return }
                self.active[xid] = Outgoing(xid: xid, name: name, size: size, url: url, sha: sha)
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                self.send(Message("xfer.offer", ["xid": xid, "kind": "file", "name": name, "size": size, "mime": mime])) { _ in }
            }
        }
        return xid
    }

    public func handle(_ m: Message) {
        guard let xid = m.string("xid"), let o = active[xid] else { return }
        switch m.type {
        case "xfer.accept":
            o.offset = m.int("offset") ?? 0
            o.streaming = true
            pump(o)
        case "xfer.skip":
            active[xid] = nil
            emit(.finished(xid: xid, name: o.name, skipped: true))
        case "xfer.done":
            active[xid] = nil
            if m.bool("ok") == true { emit(.finished(xid: xid, name: o.name, skipped: false)) }
            else { emit(.failed(xid: xid, name: o.name, error: m.string("error") ?? "The phone couldn't save it")) }
        case "xfer.cancel":
            active[xid] = nil
            emit(.failed(xid: xid, name: o.name, error: "Cancelled on the phone"))
        default: break
        }
    }

    public func connectionClosed() {
        for o in active.values { emit(.failed(xid: o.xid, name: o.name, error: "Phone disconnected")) }
        active.removeAll()
    }

    private func pump(_ o: Outgoing) {
        guard active[o.xid] === o, o.streaming else { return }
        if o.offset >= o.size {
            o.streaming = false
            send(Message("xfer.end", ["xid": o.xid, "sha256": o.sha])) { _ in }
            return
        }
        let chunk: Data
        do {
            let h = try FileHandle(forReadingFrom: o.url)
            defer { try? h.close() }
            try h.seek(toOffset: UInt64(o.offset))
            chunk = try h.read(upToCount: transferChunkSize) ?? Data()
        } catch {
            active[o.xid] = nil
            emit(.failed(xid: o.xid, name: o.name, error: "Couldn't read the file"))
            send(Message("xfer.cancel", ["xid": o.xid])) { _ in }
            return
        }
        if chunk.isEmpty { o.offset = o.size; pump(o); return }
        let off = o.offset
        o.offset += Int64(chunk.count)
        emit(.progress(TransferProgress(xid: o.xid, name: o.name, kind: "file", outgoing: true, done: o.offset, total: o.size)))
        send(Message("xfer.chunk", ["xid": o.xid, "offset": off], payload: chunk)) { [weak self] ok in
            self?.queue.async {
                guard let self else { return }
                if ok { self.pump(o) }
            }
        }
    }
}

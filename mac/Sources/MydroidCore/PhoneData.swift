import Foundation

// Models and decoders for PROTOCOL.md 7.5 (SMS), 7.7 (photo library) and 7.8 (calls history).
// Ids are not typed by the protocol (Android uses longs), so `WireID` accepts a number or a string and
// echoes whichever the phone used when the Mac sends it back.

/// An id as the phone wrote it: a JSON number or a string.
public struct WireID: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let text: String
    public let numeric: Bool

    public init(_ text: String, numeric: Bool = false) { self.text = text; self.numeric = numeric }
    public init(stringLiteral value: String) { self.init(value) }

    public init?(any v: Any?) {
        if let s = v as? String, !s.isEmpty { self.init(s); return }
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            self.init(Double(n.int64Value) == n.doubleValue ? String(n.int64Value) : n.stringValue, numeric: true)
            return
        }
        return nil
    }

    /// What goes back on the wire.
    public var json: Any {
        if numeric, let n = Int64(text) { return n }
        return text
    }

    public var description: String { text }
}

func millisDate(_ v: Any?) -> Date? {
    guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
    return Date(timeIntervalSince1970: n.doubleValue / 1000)
}

func millis(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }

// MARK: SMS (7.5)

public struct SmsThread: Sendable, Equatable, Identifiable {
    public var id: WireID
    public var addresses: [String]
    public var name: String
    public var snippet: String
    public var date: Date
    public var unread: Int
    public var avatar: Data?

    public init(id: WireID, addresses: [String] = [], name: String = "", snippet: String = "", date: Date = Date(),
                unread: Int = 0, avatar: Data? = nil) {
        self.id = id; self.addresses = addresses; self.name = name; self.snippet = snippet
        self.date = date; self.unread = unread; self.avatar = avatar
    }

    public init?(fields f: [String: Any]) {
        guard let id = WireID(any: f["threadId"]) else { return nil }
        let addrs = (f["addresses"] as? [Any])?.compactMap { $0 as? String } ?? []
        let name = (f["name"] as? String) ?? ""
        self.init(id: id, addresses: addrs, name: name.isEmpty ? (addrs.first ?? "") : name,
                  snippet: f["snippet"] as? String ?? "", date: millisDate(f["date"]) ?? Date(timeIntervalSince1970: 0),
                  unread: (f["unread"] as? NSNumber)?.intValue ?? 0,
                  avatar: (f["avatar"] as? String).flatMap { Data(base64Encoded: $0) })
    }

    public var isGroup: Bool { addresses.count > 1 }
}

public enum SmsStatus: String, Sendable, Equatable { case received, sent, pending, failed }

public struct SmsMessage: Sendable, Equatable, Identifiable {
    public var id: WireID
    public var from: String
    public var body: String
    public var date: Date
    public var out: Bool
    public var status: SmsStatus
    public var mms: Bool

    public init(id: WireID, from: String = "", body: String, date: Date, out: Bool, status: SmsStatus = .received, mms: Bool = false) {
        self.id = id; self.from = from; self.body = body; self.date = date; self.out = out; self.status = status; self.mms = mms
    }

    public init?(fields f: [String: Any]) {
        guard let date = millisDate(f["date"]) else { return nil }
        let body = f["body"] as? String ?? ""
        let out = f["out"] as? Bool ?? false
        let id = WireID(any: f["id"]) ?? WireID("\(millis(date))-\(out ? "o" : "i")-\(body.hashValue)")
        self.init(id: id, from: f["from"] as? String ?? "", body: body, date: date, out: out,
                  status: (f["status"] as? String).flatMap(SmsStatus.init(rawValue:)) ?? (out ? .sent : .received),
                  mms: f["mms"] as? Bool ?? false)
    }
}

public struct SmsSent: Sendable, Equatable {
    public var clientId: String
    public var ok: Bool
    public var error: String?
    public var threadId: WireID?
}

public enum SmsDecode {
    public static func threads(_ m: Message) -> [SmsThread] { (m.array("threads") ?? []).compactMap(SmsThread.init(fields:)) }

    public static func messages(_ m: Message) -> (threadId: WireID, messages: [SmsMessage])? {
        guard let id = WireID(any: m.fields["threadId"]) else { return nil }
        return (id, (m.array("messages") ?? []).compactMap(SmsMessage.init(fields:)))
    }

    public static func sent(_ m: Message) -> SmsSent? {
        guard let c = m.string("clientId") else { return nil }
        return SmsSent(clientId: c, ok: m.bool("ok") ?? false, error: m.string("error"), threadId: WireID(any: m.fields["threadId"]))
    }

    public static func changed(_ m: Message) -> WireID? { WireID(any: m.fields["threadId"]) }
}

/// What `sms.threads.get` asked for, so the matching `sms.threads` can be interpreted (the reply isn't correlated).
public struct SmsThreadsRequest: Sendable, Equatable {
    public var limit: Int
    public var before: Date?
}

// MARK: Photo library (7.7)

public enum PhotoAlbum: String, Sendable, CaseIterable, Identifiable, Hashable {
    case all, camera, screenshots
    public var id: String { rawValue }
    public var title: String {
        switch self { case .all: return "All"; case .camera: return "Camera"; case .screenshots: return "Screenshots" }
    }
}

public struct PhotoItem: Sendable, Equatable, Identifiable, Hashable {
    public var id: WireID
    public var name: String
    public var taken: Date
    public var width: Int
    public var height: Int
    public var size: Int64
    public var mime: String
    public var album: String

    public init(id: WireID, name: String, taken: Date, width: Int = 0, height: Int = 0, size: Int64 = 0,
                mime: String = "image/jpeg", album: String = "camera") {
        self.id = id; self.name = name; self.taken = taken; self.width = width; self.height = height
        self.size = size; self.mime = mime; self.album = album
    }

    public init?(fields f: [String: Any]) {
        guard let id = WireID(any: f["id"]) else { return nil }
        func int(_ k: String) -> Int { (f[k] as? NSNumber)?.intValue ?? 0 }
        self.init(id: id, name: f["name"] as? String ?? "Photo \(id.text)",
                  taken: millisDate(f["taken"]) ?? Date(timeIntervalSince1970: 0), width: int("w"), height: int("h"),
                  size: (f["size"] as? NSNumber)?.int64Value ?? 0, mime: f["mime"] as? String ?? "image/jpeg",
                  album: f["album"] as? String ?? "camera")
    }

    public var isVideo: Bool { mime.hasPrefix("video/") }
    public var aspect: Double { width > 0 && height > 0 ? Double(width) / Double(height) : 1 }
}

public struct PhotosPage: Sendable, Equatable {
    public var album: PhotoAlbum
    public var before: Date?
    public var items: [PhotoItem]
    public var more: Bool
    /// `"permission"` when the phone may not read its photos (the page is then empty).
    public var error: String?
}

/// What `photos.list` asked for.
public struct PhotosRequest: Sendable, Equatable {
    public var album: PhotoAlbum
    public var before: Date?
}

public enum PhotosDecode {
    public static func page(_ m: Message, request: PhotosRequest?) -> PhotosPage? {
        // The phone may echo the album; otherwise use what we asked for.
        let album = m.string("album").flatMap(PhotoAlbum.init(rawValue:)) ?? request?.album
        guard let album else { return nil }
        let items = (m.array("items") ?? []).compactMap(PhotoItem.init(fields:))
        return PhotosPage(album: album, before: request?.before, items: items, more: m.bool("more") ?? false, error: m.string("error"))
    }
}

// MARK: Calls (7.8)

public enum CallKind: String, Sendable, Equatable, CaseIterable {
    case incoming = "in", outgoing = "out", missed, rejected
}

public struct CallRecord: Sendable, Equatable, Identifiable {
    public var id: String
    public var number: String
    public var name: String
    public var kind: CallKind
    public var date: Date
    /// Seconds.
    public var duration: Int

    public init(number: String, name: String = "", kind: CallKind, date: Date, duration: Int = 0) {
        self.number = number; self.name = name; self.kind = kind; self.date = date; self.duration = duration
        id = "\(millis(date))|\(number)|\(kind.rawValue)"
    }

    public init?(fields f: [String: Any]) {
        guard let date = millisDate(f["date"]) else { return nil }
        let number = f["number"] as? String ?? ""
        let name = f["name"] as? String ?? ""
        guard let kind = (f["kind"] as? String).flatMap(CallKind.init(rawValue:)) else { return nil }
        self.init(number: number, name: name, kind: kind, date: date, duration: (f["duration"] as? NSNumber)?.intValue ?? 0)
    }

    /// Contact name, else the number, else "Unknown".
    public var title: String { !name.isEmpty ? name : (!number.isEmpty ? number : "Unknown") }
    public var isMissed: Bool { kind == .missed || kind == .rejected }

    public static func page(_ m: Message) -> [CallRecord] { (m.array("items") ?? []).compactMap(CallRecord.init(fields:)) }
}

// MARK: Request bookkeeping

/// Replies to `sms.threads.get` and `photos.list` carry no request id, so the Hub remembers what it asked
/// (oldest first) and pairs each reply with the oldest request that hasn't expired.
public struct RequestBook<Request: Sendable>: Sendable {
    private var entries: [(request: Request, at: Date)] = []
    public var lifetime: TimeInterval
    public init(lifetime: TimeInterval = 30) { self.lifetime = lifetime }

    public mutating func push(_ r: Request, now: Date = Date()) {
        prune(now)
        entries.append((r, now))
        if entries.count > 16 { entries.removeFirst(entries.count - 16) }
    }

    /// The request this reply answers, or nil when nothing is outstanding (a late reply).
    public mutating func pop(now: Date = Date()) -> Request? {
        prune(now)
        return entries.isEmpty ? nil : entries.removeFirst().request
    }

    public mutating func removeAll() { entries.removeAll() }
    public var count: Int { entries.count }

    private mutating func prune(_ now: Date) { entries.removeAll { now.timeIntervalSince($0.at) > lifetime } }
}

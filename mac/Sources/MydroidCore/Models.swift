import Foundation

public enum FeatureState: String, Sendable, Equatable {
    case on, off, needsPermission = "needs_permission", unknown
}

public enum NetworkKind: String, Sendable, Equatable { case wifi, cellular, none }

public struct SyncSettings: Codable, Sendable, Equatable {
    public var notifications = true
    public var photos = true
    public var calls = true
    public var clipboard = false
    /// v1.2 (PROTOCOL.md 7.2)
    public var mutedApps: [String] = []
    public var screenshots = true
    /// Pause photo sync while the phone is below this percentage and not charging. nil = never.
    public var pauseBelowBattery: Int? = nil
    public var smsHistory = false
    public var media = true
    /// v1.3 (PROTOCOL.md 8): the user turned on Mac call audio, so the phone keeps wireless debugging alive.
    public var callAudio = false
    /// v1.5 (PROTOCOL.md 12): walk-away lock is on, so the phone advertises its BLE service for the Mac to scan.
    public var walkAway = false

    public init(notifications: Bool = true, photos: Bool = true, calls: Bool = true, clipboard: Bool = false,
                mutedApps: [String] = [], screenshots: Bool = true, pauseBelowBattery: Int? = nil,
                smsHistory: Bool = false, media: Bool = true, callAudio: Bool = false, walkAway: Bool = false) {
        self.notifications = notifications; self.photos = photos; self.calls = calls; self.clipboard = clipboard
        self.mutedApps = mutedApps; self.screenshots = screenshots; self.pauseBelowBattery = pauseBelowBattery
        self.smsHistory = smsHistory; self.media = media; self.callAudio = callAudio; self.walkAway = walkAway
    }

    // Settings saved by older builds lack the v1.2 keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? true
        photos = try c.decodeIfPresent(Bool.self, forKey: .photos) ?? true
        calls = try c.decodeIfPresent(Bool.self, forKey: .calls) ?? true
        clipboard = try c.decodeIfPresent(Bool.self, forKey: .clipboard) ?? false
        mutedApps = try c.decodeIfPresent([String].self, forKey: .mutedApps) ?? []
        screenshots = try c.decodeIfPresent(Bool.self, forKey: .screenshots) ?? true
        pauseBelowBattery = try c.decodeIfPresent(Int.self, forKey: .pauseBelowBattery)
        smsHistory = try c.decodeIfPresent(Bool.self, forKey: .smsHistory) ?? false
        media = try c.decodeIfPresent(Bool.self, forKey: .media) ?? true
        callAudio = try c.decodeIfPresent(Bool.self, forKey: .callAudio) ?? false
        walkAway = try c.decodeIfPresent(Bool.self, forKey: .walkAway) ?? false
    }

    public static let all = SyncSettings(notifications: true, photos: true, calls: true, clipboard: true)

    /// The `settings` message body.
    public var wireFields: [String: Any] {
        ["notifications": notifications, "photos": photos, "calls": calls, "clipboard": clipboard,
         "mutedApps": mutedApps.sorted(), "screenshots": screenshots,
         "pauseBelowBattery": pauseBelowBattery.map { $0 as Any } ?? NSNull(),
         "smsHistory": smsHistory, "media": media, "callAudio": callAudio, "walkAway": walkAway]
    }
}

public struct FeatureStatus: Sendable, Equatable {
    public var notifications: FeatureState = .unknown
    public var photos: FeatureState = .unknown
    public var calls: FeatureState = .unknown
    public var clipboard: FeatureState = .unknown
    public var backgroundRestricted = false
    public init() {}
}

public enum FixKind: String, Sendable, Equatable, CaseIterable {
    case notifications, photos, calls, background
    /// Text messages (READ_SMS / SEND_SMS). Not part of `HubState.fixes`; the Messages view asks for it after `sms.error`.
    case sms
    /// Developer options (call audio setup, PROTOCOL.md 8.2). Not part of `HubState.fixes`.
    case devoptions
}

public struct PhoneInfo: Sendable, Equatable {
    public var name: String
    public var model: String
    public var battery: Int?
    public var charging = false
    public var network: NetworkKind?
    public var lowPowerMode = false
    public init(name: String, model: String = "", battery: Int? = nil, charging: Bool = false, network: NetworkKind? = nil,
                lowPowerMode: Bool = false) {
        self.name = name; self.model = model; self.battery = battery; self.charging = charging; self.network = network
        self.lowPowerMode = lowPowerMode
    }
}

public struct NotificationAction: Sendable, Equatable {
    public var index: Int
    public var title: String
}

public enum NotificationCategory: String, Sendable, Equatable { case message, other }

public struct ConversationMessage: Sendable, Equatable {
    public var sender: String     // "" for messages the user sent
    public var text: String
    public var when: Date
    public var isMine: Bool { sender.isEmpty }
    public init(sender: String, text: String, when: Date) { self.sender = sender; self.text = text; self.when = when }
}

public struct Conversation: Sendable, Equatable {
    public var title: String
    public var isGroup: Bool
    public var messages: [ConversationMessage]   // last <= 5, oldest first
    public var avatar: Data?
    public init(title: String, isGroup: Bool = false, messages: [ConversationMessage] = [], avatar: Data? = nil) {
        self.title = title; self.isGroup = isGroup; self.messages = messages; self.avatar = avatar
    }
    public var last: ConversationMessage? { messages.last }
}

/// A one-time code found in a notification (PROTOCOL.md 5.1).
public struct OneTimeCode: Sendable, Equatable {
    /// How long a code stays on offer after the notification's `when`.
    public static var lifetime: TimeInterval = 600
    public var code: String
    public var source: String
    public init(code: String, source: String = "") { self.code = code; self.source = source }

    /// "482196" -> "482 196". Odd lengths and codes with letters are left alone.
    public var grouped: String {
        let c = Array(code)
        guard c.allSatisfy({ $0.isNumber }) else { return code }
        let size: Int
        switch c.count {
        case 6: size = 3
        case 8: size = 4
        case 9: size = 3
        default: return code
        }
        return stride(from: 0, to: c.count, by: size).map { String(c[$0..<min($0 + size, c.count)]) }.joined(separator: " ")
    }
}

/// The sender of a message notification (PROTOCOL.md 13.1). `phone` is E.164 when the phone knew it.
public struct NotificationPerson: Sendable, Equatable {
    public var name: String
    public var phone: String?
    public init(name: String, phone: String? = nil) { self.name = name; self.phone = phone }

    /// "+91 98765-43210" -> "+919876543210". Anything that cannot be a phone number gives nil.
    public static func normalizedPhone(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let digits = raw.filter { $0.isASCII && $0.isNumber }
        guard (6...15).contains(digits.count) else { return nil }
        let allowed = raw.allSatisfy { $0.isNumber || " +-().".contains($0) }
        guard allowed else { return nil }
        return "+" + digits
    }
}

/// A media-style notification (PROTOCOL.md 13.1).
public struct NotificationMedia: Sendable, Equatable {
    public var title: String
    public var artist: String
    public var album: String?
    public var mediaId: String?
    public init(title: String, artist: String, album: String? = nil, mediaId: String? = nil) {
        self.title = title; self.artist = artist; self.album = album; self.mediaId = mediaId
    }
}

public struct PhoneNotification: Sendable, Equatable, Identifiable {
    public var id: String { key }
    public var key: String
    public var pkg: String
    public var app: String
    public var title: String
    public var text: String
    public var when: Date
    public var canReply: Bool
    public var actions: [NotificationAction]
    public var icon: Data?
    public var category: NotificationCategory
    public var conversation: Conversation?
    public var otp: OneTimeCode?
    /// v1.6 (PROTOCOL.md 13.1), all optional.
    public var person: NotificationPerson?
    /// http(s) links found in the notification, at most 3.
    public var links: [URL]
    public var media: NotificationMedia?

    public init(key: String, pkg: String = "", app: String = "", title: String = "", text: String = "",
                when: Date = Date(), canReply: Bool = false, actions: [NotificationAction] = [], icon: Data? = nil,
                category: NotificationCategory = .other, conversation: Conversation? = nil, otp: OneTimeCode? = nil,
                person: NotificationPerson? = nil, links: [URL] = [], media: NotificationMedia? = nil) {
        self.key = key; self.pkg = pkg; self.app = app; self.title = title; self.text = text
        self.when = when; self.canReply = canReply; self.actions = actions; self.icon = icon
        self.category = category; self.conversation = conversation; self.otp = otp
        self.person = person; self.links = links; self.media = media
    }

    /// Parses a `notif.posted` body (also used for `notif.snapshot` items). Rich fields are optional.
    public init?(fields f: [String: Any]) {
        guard let key = f["key"] as? String else { return nil }
        let msg = Message("notif.posted", f)
        func millis(_ v: Any?) -> Date? {
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            return Date(timeIntervalSince1970: n.doubleValue / 1000)
        }
        var conversation: Conversation?
        if let c = f["conversation"] as? [String: Any] {
            let msgs: [ConversationMessage] = ((c["messages"] as? [[String: Any]]) ?? []).compactMap {
                guard let text = $0["text"] as? String else { return nil }
                return ConversationMessage(sender: $0["sender"] as? String ?? "", text: text, when: millis($0["when"]) ?? Date())
            }
            conversation = Conversation(title: c["title"] as? String ?? "", isGroup: c["isGroup"] as? Bool ?? false,
                                        messages: Array(msgs.suffix(5)),
                                        avatar: (c["avatar"] as? String).flatMap { Data(base64Encoded: $0) })
        }
        var otp: OneTimeCode?
        if let o = f["otp"] as? [String: Any], let code = o["code"] as? String, !code.isEmpty {
            otp = OneTimeCode(code: code, source: o["source"] as? String ?? "")
        }
        var person: NotificationPerson?
        if let p = f["person"] as? [String: Any], let name = p["name"] as? String {
            person = NotificationPerson(name: name, phone: NotificationPerson.normalizedPhone(p["phone"] as? String))
        }
        var links: [URL] = []
        for raw in (f["links"] as? [Any]) ?? [] {
            guard let s = raw as? String, let u = LinkPolicy.parse(s), LinkPolicy.isWeb(u), !links.contains(u) else { continue }
            links.append(u)
            if links.count == 3 { break }
        }
        var media: NotificationMedia?
        if let m = f["media"] as? [String: Any], let title = m["title"] as? String {
            let id = (m["mediaId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            media = NotificationMedia(title: title, artist: m["artist"] as? String ?? "",
                                      album: (m["album"] as? String).flatMap { $0.isEmpty ? nil : $0 }, mediaId: id)
        }
        self.init(
            key: key,
            pkg: msg.string("pkg") ?? "",
            app: msg.string("app") ?? "",
            title: msg.string("title") ?? "",
            text: msg.string("text") ?? "",
            when: millis(f["when"]) ?? Date(),
            canReply: msg.bool("canReply") ?? false,
            actions: (msg.array("actions") ?? []).compactMap {
                guard let i = (($0["index"] as? NSNumber)?.intValue), let t = $0["title"] as? String else { return nil }
                return NotificationAction(index: i, title: t)
            },
            icon: (f["icon"] as? String).flatMap { Data(base64Encoded: $0) },
            category: (msg.string("category")).flatMap(NotificationCategory.init(rawValue:)) ?? .other,
            conversation: conversation, otp: otp, person: person, links: links, media: media)
    }

    /// Initials for the avatar: "Maya Tan" -> "MT".
    public var initials: String {
        let source = title.isEmpty ? displayApp : title
        let parts = source.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2)
        let s = parts.compactMap { $0.first }.map { String($0).uppercased() }.joined()
        return s.isEmpty ? "?" : s
    }

    /// Human app name, even when an older phone build sent the package name.
    public var displayApp: String { AppNames.present(app.isEmpty ? pkg : app) }

    public var isMessage: Bool { category == .message }

    /// The conversation to show for a message. Older or sparse payloads get a one-message conversation.
    public var effectiveConversation: Conversation? {
        guard isMessage else { return nil }
        if let c = conversation, !c.messages.isEmpty || !c.title.isEmpty {
            if !c.messages.isEmpty { return c }
            var c2 = c; c2.messages = [ConversationMessage(sender: c.isGroup ? "" : c.title, text: text, when: when)]; return c2
        }
        return Conversation(title: title.isEmpty ? displayApp : title, isGroup: false,
                            messages: [ConversationMessage(sender: title, text: text, when: when)])
    }

    public var otpExpiry: Date? { otp == nil ? nil : when.addingTimeInterval(OneTimeCode.lifetime) }
    /// True while the code can still be offered.
    public func hasActiveCode(at now: Date = Date()) -> Bool {
        guard let exp = otpExpiry else { return false }
        return now < exp
    }
}

/// Turns package-looking app names ("com.whatsapp") into something presentable.
public enum AppNames {
    static let known: [String: String] = [
        "com.whatsapp": "WhatsApp", "com.whatsapp.w4b": "WhatsApp Business",
        "com.google.android.gm": "Gmail", "com.google.android.apps.messaging": "Messages",
        "com.android.mms": "Messages", "com.samsung.android.messaging": "Messages",
        "org.telegram.messenger": "Telegram", "org.thoughtcrime.securesms": "Signal",
        "com.instagram.android": "Instagram", "com.slack": "Slack",
        "com.facebook.orca": "Messenger", "com.facebook.katana": "Facebook",
        "com.twitter.android": "X", "com.discord": "Discord", "com.snapchat.android": "Snapchat",
        "com.microsoft.teams": "Teams", "com.linkedin.android": "LinkedIn", "com.spotify.music": "Spotify",
        "com.google.android.youtube": "YouTube", "com.reddit.frontpage": "Reddit",
        "com.google.android.calendar": "Calendar", "com.google.android.dialer": "Phone",
        "com.google.android.apps.maps": "Maps", "com.android.vending": "Play Store",
        "com.google.android.apps.nbu.paisa.user": "Google Pay", "com.phonepe.app": "PhonePe",
        "com.amazon.mshop.android.shopping": "Amazon", "in.amazon.mshop.android.shopping": "Amazon",
        "com.google.android.apps.photos": "Photos", "com.microsoft.office.outlook": "Outlook",
    ]
    private static let generic: Set<String> = ["android", "app", "mobile", "main", "client", "prod"]

    public static func looksLikePackage(_ s: String) -> Bool { s.contains(".") && !s.contains(" ") }

    public static func present(_ s: String) -> String {
        guard looksLikePackage(s) else { return s }
        if let n = known[s.lowercased()] { return n }
        let parts = s.split(separator: ".").map(String.init)
        guard var name = parts.last else { return s }
        if generic.contains(name.lowercased()), parts.count > 1 { name = parts[parts.count - 2] }
        guard let first = name.first else { return s }
        return first.uppercased() + name.dropFirst()
    }
}

/// Ordered list that mirrors the phone's notification shade.
public struct NotificationList: Sendable, Equatable {
    public private(set) var items: [PhoneNotification] = []
    public init() {}

    /// Returns true when the notification is new, or an update that carries a newer `when`
    /// (a fresh message in an existing conversation).
    @discardableResult
    public mutating func post(_ n: PhoneNotification) -> Bool {
        if let i = items.firstIndex(where: { $0.key == n.key }) {
            let fresh = n.when > items[i].when
            items[i] = n
            return fresh
        }
        items.insert(n, at: 0)
        return true
    }
    public mutating func remove(_ key: String) { items.removeAll { $0.key == key } }
    public mutating func replace(with list: [PhoneNotification]) {
        items = list.sorted { $0.when > $1.when }
    }
    public mutating func clear() { items = [] }

    /// Conversations, newest first.
    public var messages: [PhoneNotification] { items.filter(\.isMessage).sorted { $0.when > $1.when } }
    /// Everything that is not a message, newest first.
    public var others: [PhoneNotification] { items.filter { !$0.isMessage }.sorted { $0.when > $1.when } }
    /// Notifications whose one-time code is still on offer, newest first.
    public func activeCodes(at now: Date = Date()) -> [PhoneNotification] {
        items.filter { $0.hasActiveCode(at: now) }.sorted { $0.when > $1.when }
    }
}

public enum CallPhase: String, Sendable, Equatable { case ringing, active, ended }

public struct CallInfo: Sendable, Equatable, Identifiable {
    public var id: String { callId }
    public var callId: String
    public var phase: CallPhase
    public var incoming: Bool
    public var number: String?
    public var name: String?
    public var startedAt: Date
    public var muted = false

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        if let number, !number.isEmpty { return number }
        // Outgoing: the number usually arrives a moment later; never call your own call "unknown".
        return incoming ? "No caller ID" : "Outgoing call"
    }
    public var initials: String {
        guard let name, !name.isEmpty else { return "#" }
        let s = name.split(separator: " ").prefix(2).compactMap { $0.first }.map { String($0).uppercased() }.joined()
        return s.isEmpty ? "#" : s
    }
}

public struct SavedFile: Sendable, Equatable, Identifiable {
    public var id: String { xid }
    public var xid: String
    public var kind: String
    public var url: URL
    public var name: String
    public var size: Int64
    public var taken: Date?
    public var savedAt: Date
}

public struct TransferProgress: Sendable, Equatable, Identifiable {
    public var id: String { xid }
    public var xid: String
    public var name: String
    public var kind: String
    public var outgoing: Bool
    public var done: Int64
    public var total: Int64
    public var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
}

public struct PairingInfo: Sendable, Equatable {
    public var url: String
    public var expires: Date
    public var confirmCode: String?   // six digits, once a phone has connected
    public var phoneName: String?
}

public enum LinkState: Sendable, Equatable { case unpaired, searching, connected }

public struct HubState: Sendable, Equatable {
    public var link: LinkState = .unpaired
    public var phone: PhoneInfo?
    public var lastSeen: Date?
    public var features = FeatureStatus()
    public var settings = SyncSettings()
    public var notifications = NotificationList()
    public var call: CallInfo?
    public var latestPhoto: SavedFile?
    public var transfers: [TransferProgress] = []
    public var pairing: PairingInfo?
    public var port: UInt16?
    public var listenerError: String?
    /// Now-playing state from the phone (7.3), nil when nothing is active.
    public var media: MediaState?
    /// BLE presence service UUID for the current pairing (7.1).
    public var bleUUID: String?
    /// The service UUID the phone advertises for walk-away lock (PROTOCOL.md 12).
    public var phoneBleUUID: String?
    /// What the Mac told the phone about Remote: Accessibility, and whether a slideshow is on (PROTOCOL.md 10).
    public var remote = RemoteStatus()
    /// The last `mac.status` we know of (PROTOCOL.md 11), nil until the app reports one.
    public var macStatus: MacStatus?
    /// The phone's IPv4 address on the Mydroid connection while connected (used to find it again for wireless debugging).
    public var phoneHost: String?
    public init() {}

    public var photoSyncing: Bool { transfers.contains { !$0.outgoing && $0.kind == "photo" } }

    /// Things the user can fix from the Mac (connected only).
    public var fixes: [FixKind] {
        guard link == .connected else { return [] }
        var out: [FixKind] = []
        if features.backgroundRestricted { out.append(.background) }
        if settings.notifications && features.notifications == .needsPermission { out.append(.notifications) }
        if settings.photos && features.photos == .needsPermission { out.append(.photos) }
        if settings.calls && features.calls == .needsPermission { out.append(.calls) }
        return out
    }
}

/// Clipboard echo suppression. Pure logic so it can be tested without a pasteboard.
public struct ClipboardGuard: Sendable {
    private var lastRemote: String?
    private var lastSent: String?
    public init() {}

    /// Pasteboard types that password managers and apps use to say "don't sync this" (PROTOCOL.md 7.2).
    public static let sensitiveTypes: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
    public static func isSensitive(types: [String]) -> Bool { types.contains { sensitiveTypes.contains($0) } }

    /// A local clipboard change. Returns the text to send, or nil if it should be suppressed.
    public mutating func localChanged(_ text: String) -> String? {
        if text == lastRemote || text == lastSent { return nil }
        guard !text.isEmpty, text.utf8.count <= 1 << 20 else { return nil }
        lastSent = text
        return text
    }
    public mutating func remoteArrived(_ text: String) { lastRemote = text; lastSent = text }
    public mutating func reset() { lastRemote = nil; lastSent = nil }
}

// MARK: v1.2 models

/// What the phone is playing (PROTOCOL.md 7.3).
public struct MediaState: Sendable, Equatable {
    public var pkg: String
    public var app: String
    public var title: String
    public var artist: String
    public var album: String
    public var art: Data?
    public var playing: Bool
    public var position: Int64      // ms, sampled at `ts`
    public var duration: Int64      // ms
    public var ts: Date
    public var canSeek: Bool
    public var canNext: Bool
    public var canPrev: Bool
    /// `spotify:track:...`, `spotify:episode:...` or an http(s) URL (PROTOCOL.md 15), already filtered. Sent when the track changes.
    public var mediaId: String?

    public init(pkg: String = "", app: String = "", title: String = "", artist: String = "", album: String = "",
                art: Data? = nil, playing: Bool = false, position: Int64 = 0, duration: Int64 = 0, ts: Date = Date(),
                canSeek: Bool = false, canNext: Bool = true, canPrev: Bool = true, mediaId: String? = nil) {
        self.pkg = pkg; self.app = app; self.title = title; self.artist = artist; self.album = album; self.art = art
        self.playing = playing; self.position = position; self.duration = duration; self.ts = ts
        self.canSeek = canSeek; self.canNext = canNext; self.canPrev = canPrev
        self.mediaId = MediaRef.filtered(mediaId)
    }

    /// Position extrapolated from the sample, no networking.
    public func position(at now: Date) -> Int64 {
        guard playing else { return min(position, duration > 0 ? duration : position) }
        let elapsed = Int64(max(0, now.timeIntervalSince(ts)) * 1000)
        let p = position + elapsed
        return duration > 0 ? min(p, duration) : p
    }

    public func fraction(at now: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, Double(position(at: now)) / Double(duration)))
    }

    public var displayApp: String { AppNames.present(app.isEmpty ? pkg : app) }
    /// Same track as `other` (art is only re-sent when the track changes).
    public func sameTrack(as other: MediaState) -> Bool {
        pkg == other.pkg && title == other.title && artist == other.artist && album == other.album
    }

    /// Parses `media.state`. Returns nil when `active` is false or the body is unusable.
    public init?(message m: Message) {
        guard m.bool("active") == true else { return nil }
        let ts = m.int("ts").map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? Date()
        self.init(pkg: m.string("pkg") ?? "", app: m.string("app") ?? "", title: m.string("title") ?? "",
                  artist: m.string("artist") ?? "", album: m.string("album") ?? "",
                  art: m.string("art").flatMap { Data(base64Encoded: $0) },
                  playing: m.bool("playing") ?? false, position: m.int("position") ?? 0, duration: m.int("duration") ?? 0,
                  ts: ts, canSeek: m.bool("canSeek") ?? false, canNext: m.bool("canNext") ?? true, canPrev: m.bool("canPrev") ?? true,
                  mediaId: m.string("mediaId"))
    }
}

/// One "battery is low" alert per discharge (PROTOCOL.md 7.9): fires on the first report below 20% while not
/// charging, and re-arms once the phone is charging.
public struct LowBatteryTracker: Sendable {
    public static let threshold = 20
    private var alerted = false
    public init() {}

    /// True when a banner should be shown for this report.
    public mutating func update(battery: Int?, charging: Bool) -> Bool {
        if charging { alerted = false; return false }
        guard let battery else { return false }
        if battery >= Self.threshold { return false }   // stays armed state unchanged until charging resets
        if alerted { return false }
        alerted = true
        return true
    }
    public mutating func reset() { alerted = false }
}

/// Links are limited to http, https and mailto (PROTOCOL.md 7.4).
public enum LinkPolicy {
    public static let schemes: Set<String> = ["http", "https", "mailto"]
    /// http and https only: what a notification's own links may be (PROTOCOL.md 13.1).
    public static func isWeb(_ url: URL) -> Bool {
        guard let s = url.scheme?.lowercased(), s == "http" || s == "https" else { return false }
        return url.host?.isEmpty == false
    }
    public static func allowed(_ url: URL) -> Bool {
        guard let s = url.scheme?.lowercased(), schemes.contains(s) else { return false }
        if s == "mailto" { return !url.absoluteString.dropFirst(7).isEmpty }
        return url.host?.isEmpty == false
    }
    public static func parse(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(where: \.isWhitespace), let u = URL(string: t), allowed(u) else { return nil }
        return u
    }
}

/// What "send to phone" was asked to send (Services menu, URL scheme, drops).
public enum SendPayload: Equatable, Sendable {
    case files([URL])
    case link(URL)
    case text(String)

    /// A single URL becomes a link, anything else is text.
    public static func classify(text: String) -> SendPayload? {
        if let u = LinkPolicy.parse(text) { return .link(u) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .text(text)
    }

    /// `mydroid://send?url=...`, `?text=...`, `?file=<path>`.
    public static func parse(schemeURL u: URL) -> SendPayload? {
        guard u.scheme?.lowercased() == "mydroid", (u.host ?? "").lowercased() == "send",
              let items = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ k: String) -> String? { items.first { $0.name == k }?.value }
        if let s = value("url") { return LinkPolicy.parse(s).map(SendPayload.link) }
        if let t = value("text") { return classify(text: t) }
        if let f = value("file"), !f.isEmpty {
            let path = (f as NSString).expandingTildeInPath
            guard path.hasPrefix("/") else { return nil }
            return .files([URL(fileURLWithPath: path)])
        }
        return nil
    }
}

/// Muted-or-not logic for "quiet hours" (banners are suppressed, the list is kept).
public struct QuietHours: Codable, Sendable, Equatable {
    public var enabled = false
    public var from = 22 * 60     // minutes after midnight
    public var to = 7 * 60
    public init(enabled: Bool = false, from: Int = 22 * 60, to: Int = 7 * 60) { self.enabled = enabled; self.from = from; self.to = to }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, from != to else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return from < to ? (m >= from && m < to) : (m >= from || m < to)
    }
}

/// Every app the phone has sent a notification for, for the per-app list in Settings.
public struct KnownApps: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable { public var name: String; public var icon: Data? }
    public private(set) var apps: [String: Entry] = [:]
    public init() {}

    /// Returns true when something changed (so the caller knows to save).
    @discardableResult
    public mutating func note(_ n: PhoneNotification) -> Bool {
        guard !n.pkg.isEmpty else { return false }
        var e = apps[n.pkg] ?? Entry(name: n.displayApp, icon: nil)
        let name = n.displayApp
        if !AppNames.looksLikePackage(name) || AppNames.looksLikePackage(e.name) { e.name = name }
        if let icon = n.icon, !icon.isEmpty { e.icon = icon }
        if apps[n.pkg] == e { return false }
        apps[n.pkg] = e
        return true
    }

    public func sorted() -> [(pkg: String, entry: Entry)] {
        apps.map { ($0.key, $0.value) }.sorted { $0.entry.name.localizedCaseInsensitiveCompare($1.entry.name) == .orderedAscending }
    }
}

public extension SavedFile {
    /// Android names screenshots "Screenshot_20250101-120000.png" (some OEMs use "Screenshot 2025-...").
    var isScreenshot: Bool { Screenshots.isScreenshot(name: name) }
}

public enum Screenshots {
    public static func isScreenshot(name: String) -> Bool {
        let n = name.lowercased()
        return n.hasPrefix("screenshot") || n.hasPrefix("screen_shot") || n.hasPrefix("screen shot")
    }
}

import Foundation

// Opening a phone notification from the Mac (PROTOCOL.md 13).
//
// The phone can't tell us where a notification's tap would go, so the Mac picks the best destination
// from what is visible: a rules table keyed by Android package (below), links in the notification,
// and "open it on the phone" for everything else. Nothing here touches AppKit or logs notification text.

/// Whether a Mac app is installed. The app target backs this with `NSWorkspace`; tests use a fake.
public protocol AppLocator: Sendable {
    func isInstalled(bundleID: String) -> Bool
}

/// A locator for a Mac with none of the apps (the default, and what the tests use unless they say otherwise).
public struct NoInstalledApps: AppLocator {
    public init() {}
    public func isInstalled(bundleID: String) -> Bool { false }
}

/// What the user chose for "When clicked" on one app (Settings > Notifications).
public enum ClickBehavior: String, Codable, Sendable, CaseIterable, Equatable {
    case `default`, phone, web, nothing
}

/// What a click on a notification does.
public enum OpenAction: Equatable, Sendable {
    /// Open this URL in the browser.
    case web(URL)
    /// Launch the Mac app, optionally with a URL. Use the web fallback if launch fails.
    case macApp(bundleID: String, url: URL?, fallback: URL?)
    /// Ask the phone to fire the notification's own tap action (`notif.open`).
    case phone(key: String)
    case none
}

/// Everything the UI needs to know about one notification: what a plain click does, and which
/// of the other menu entries exist.
public struct OpenPlan: Equatable, Sendable {
    public var primary: OpenAction
    public var phone: OpenAction
    /// "Open on web". nil when no rule (and no link) gives this notification a web page.
    public var web: URL?
    /// "Search the web". nil when there is nothing to search for.
    public var search: URL?
}

// MARK: Rules

/// One app's routing, as data. Steps are tried in order and the first whose condition holds wins.
public struct OpenRule: Sendable, Equatable {
    public enum Condition: Sendable, Equatable {
        case always
        /// `category == "message"`, or the notification has a conversation.
        case message
        /// The sender's phone number is known (and this isn't a group).
        case phone
        /// `media.mediaId` is `spotify:track:<id>`.
        case spotifyTrack
        /// The rule's extractor found something to search for.
        case query
    }

    /// URLs are templates: `{phone}` (digits of the E.164 number), `{id}` (Spotify track id), `{q}` (the
    /// rule's extracted query) are percent-encoded when filled in, `{host}` (see `hosts`) is inserted as it is.
    public enum Target: Sendable, Equatable {
        case web(String)
        /// The first installed app of `bundleIDs` opens `url`. Otherwise (or when it fails) `web` is used.
        case macApp(bundleIDs: [String], url: String?, web: String?)
        case phone
    }

    public enum Extractor: Sendable, Equatable { case none, gmailSubject, youtube }

    public struct Step: Sendable, Equatable {
        public var when: Condition
        public var target: Target
        public init(_ when: Condition, _ target: Target) { self.when = when; self.target = target }
    }

    public var id: String
    public var name: String
    /// Android package names, compared case-insensitively.
    public var packages: [String]
    /// Shown in Settings: what a click does by default.
    public var summary: String
    public var extractor: Extractor = .none
    /// `{host}` per package (lowercased), and for the rest.
    public var hosts: [String: String] = [:]
    public var defaultHost = ""
    public var steps: [Step]

    public init(id: String, name: String, packages: [String], summary: String, extractor: Extractor = .none,
                hosts: [String: String] = [:], defaultHost: String = "", steps: [Step]) {
        self.id = id; self.name = name; self.packages = packages; self.summary = summary; self.extractor = extractor
        self.hosts = hosts; self.defaultHost = defaultHost; self.steps = steps
    }

    /// Whether any step opens something on the web (so "Open on web" can exist for this app).
    public var hasWeb: Bool {
        steps.contains {
            switch $0.target {
            case .web: return true
            case let .macApp(_, _, web): return web != nil
            case .phone: return false
            }
        }
    }

    // swiftlint:disable line_length
    /// The rules table. To support another app, add a rule here.
    public static let builtIn: [OpenRule] = [
        OpenRule(id: "gmail", name: "Gmail", packages: ["com.google.android.gm"],
                 summary: "Searches Gmail for the email", extractor: .gmailSubject,
                 steps: [Step(.query, .web("https://mail.google.com/mail/u/0/#search/{q}")),
                         Step(.always, .web("https://mail.google.com/mail/u/0/#inbox"))]),
        OpenRule(id: "whatsapp", name: "WhatsApp", packages: ["com.whatsapp", "com.whatsapp.w4b"],
                 summary: "Opens the chat (Mac app, else web)",
                 steps: [Step(.phone, .macApp(bundleIDs: ["net.whatsapp.WhatsApp"], url: "whatsapp://send?phone={phone}",
                                              web: "https://web.whatsapp.com/send?phone={phone}")),
                         Step(.always, .macApp(bundleIDs: ["net.whatsapp.WhatsApp"], url: nil,
                                               web: "https://web.whatsapp.com/"))]),
        OpenRule(id: "telegram", name: "Telegram", packages: ["org.telegram.messenger"],
                 summary: "Opens the chat (Mac app, else web)",
                 steps: [Step(.phone, .macApp(bundleIDs: ["ru.keepcoder.Telegram", "org.telegram.desktop"], url: "tg://resolve?phone={phone}",
                                              web: "https://web.telegram.org/")),
                         Step(.always, .macApp(bundleIDs: ["ru.keepcoder.Telegram", "org.telegram.desktop"], url: "tg://",
                                               web: "https://web.telegram.org/"))]),
        OpenRule(id: "x", name: "X", packages: ["com.twitter.android"],
                 summary: "Opens x.com/notifications",
                 steps: [Step(.message, .web("https://x.com/messages")),
                         Step(.always, .web("https://x.com/notifications"))]),
        OpenRule(id: "instagram", name: "Instagram", packages: ["com.instagram.android"],
                 summary: "Opens instagram.com",
                 steps: [Step(.message, .web("https://www.instagram.com/direct/inbox/")),
                         Step(.always, .web("https://www.instagram.com/"))]),
        OpenRule(id: "linkedin", name: "LinkedIn", packages: ["com.linkedin.android"],
                 summary: "Opens linkedin.com/notifications",
                 steps: [Step(.message, .web("https://www.linkedin.com/messaging/")),
                         Step(.always, .web("https://www.linkedin.com/notifications/"))]),
        OpenRule(id: "youtube", name: "YouTube", packages: ["com.google.android.youtube"],
                 summary: "Searches YouTube for the video", extractor: .youtube,
                 steps: [Step(.query, .web("https://www.youtube.com/results?search_query={q}")),
                         Step(.always, .web("https://www.youtube.com/"))]),
        OpenRule(id: "spotify", name: "Spotify", packages: ["com.spotify.music"],
                 summary: "Opens the track (Mac app, else web)",
                 steps: [Step(.spotifyTrack, .macApp(bundleIDs: ["com.spotify.client"], url: "spotify:track:{id}",
                                                     web: "https://open.spotify.com/track/{id}")),
                         Step(.always, .phone)]),
        OpenRule(id: "amazon", name: "Amazon",
                 packages: ["in.amazon.mShop.android.shopping", "com.amazon.mShop.android.shopping"],
                 summary: "Opens your Amazon orders",
                 hosts: ["in.amazon.mshop.android.shopping": "www.amazon.in"], defaultHost: "www.amazon.com",
                 steps: [Step(.always, .web("https://{host}/gp/css/order-history"))]),
        OpenRule(id: "swiggy", name: "Swiggy", packages: ["in.swiggy.android"],
                 summary: "Opens your Swiggy orders",
                 steps: [Step(.always, .web("https://www.swiggy.com/my-account/orders"))]),
        OpenRule(id: "zomato", name: "Zomato", packages: ["com.application.zomato"],
                 summary: "Opens zomato.com",
                 steps: [Step(.always, .web("https://www.zomato.com/"))]),
        OpenRule(id: "uber", name: "Uber", packages: ["com.ubercab"],
                 summary: "Opens your Uber trips",
                 steps: [Step(.always, .web("https://riders.uber.com/trips"))]),
    ]
    // swiftlint:enable line_length
}

// MARK: Router

public struct OpenRouter: Sendable {
    public var rules: [OpenRule]
    public var locator: AppLocator

    public init(rules: [OpenRule] = OpenRule.builtIn, locator: AppLocator = NoInstalledApps()) {
        self.rules = rules; self.locator = locator
    }

    public func rule(forPackage pkg: String) -> OpenRule? {
        let p = pkg.lowercased()
        return rules.first { $0.packages.contains { $0.lowercased() == p } }
    }

    /// Settings shows "Open on web" for an app only when this is true.
    public func hasWebRule(forPackage pkg: String) -> Bool { rule(forPackage: pkg)?.hasWeb ?? false }

    /// "Opens x.com/notifications", or "Opens on your phone" for apps without a rule.
    public func summary(forPackage pkg: String) -> String { rule(forPackage: pkg)?.summary ?? "Opens on your phone" }

    /// What a click does for this notification under the user's choice for its app.
    public func action(for n: PhoneNotification, preference: ClickBehavior = .default) -> OpenAction {
        let plan = plan(for: n)
        switch preference {
        case .default: return plan.primary
        case .phone: return plan.phone
        case .web: return plan.web.map(OpenAction.web) ?? plan.primary
        case .nothing: return .none
        }
    }

    public func plan(for n: PhoneNotification) -> OpenPlan {
        let phone = OpenAction.phone(key: n.key)
        var primary = phone
        var web: URL?
        if let rule = rule(forPackage: n.pkg) {
            (primary, web) = resolve(rule, for: n)
        }
        // A link in the notification beats the app's page (PROTOCOL.md 13.3).
        if let link = n.links.first(where: LinkPolicy.isWeb) {
            primary = .web(link); web = link
        }
        return OpenPlan(primary: primary, phone: phone, web: web, search: Self.searchURL(for: n))
    }

    /// "Search the web": Google, for the title and text. Not offered for verification codes.
    public static func searchURL(for n: PhoneNotification) -> URL? {
        guard n.otp == nil else { return nil }
        var text = [n.title, n.text].filter { !$0.isEmpty }.joined(separator: " ")
        if text.isEmpty, let c = n.effectiveConversation?.last?.text { text = c }
        let q = Text.shorten(Text.collapse(text), to: 200)
        guard !q.isEmpty else { return nil }
        return URL(string: "https://www.google.com/search?q=" + Text.encode(q))
    }

    // MARK: Resolving

    private struct Values {
        var phone: String?
        var trackId: String?
        var query: String?
        var host: String
    }

    private func resolve(_ rule: OpenRule, for n: PhoneNotification) -> (OpenAction, URL?) {
        let isMessage = n.isMessage || n.conversation != nil
        var values = Values(phone: nil, trackId: nil, query: nil, host: rule.hosts[n.pkg.lowercased()] ?? rule.defaultHost)
        if n.conversation?.isGroup != true, let p = NotificationPerson.normalizedPhone(n.person?.phone) {
            values.phone = String(p.drop(while: { $0 == "+" }))
        }
        values.trackId = Self.spotifyTrackID(n.media?.mediaId)
        switch rule.extractor {
        case .none: break
        case .gmailSubject: values.query = Self.gmailSearch(title: n.title, text: n.text)
        case .youtube: values.query = Self.youtubeQuery(title: n.title, text: n.text)
        }
        for step in rule.steps {
            switch step.when {
            case .always: break
            case .message: if !isMessage { continue }
            case .phone: if values.phone == nil { continue }
            case .spotifyTrack: if values.trackId == nil { continue }
            case .query: if (values.query ?? "").isEmpty { continue }
            }
            switch step.target {
            case .phone:
                return (.phone(key: n.key), nil)
            case let .web(t):
                guard let u = Self.expand(t, values) else { continue }
                return (.web(u), u)
            case let .macApp(ids, url, webT):
                let web = webT.flatMap { Self.expand($0, values) }
                if let id = ids.first(where: locator.isInstalled(bundleID:)) {
                    if let url {
                        if let expanded = Self.expand(url, values) { return (.macApp(bundleID: id, url: expanded, fallback: web), web) }
                    } else {
                        return (.macApp(bundleID: id, url: nil, fallback: web), web)
                    }
                }
                if let web { return (.web(web), web) }
                continue
            }
        }
        return (.phone(key: n.key), nil)
    }

    private static func expand(_ template: String, _ v: Values) -> URL? {
        var out = template
        let pairs: [(String, String?, Bool)] = [("{phone}", v.phone, true), ("{id}", v.trackId, true),
                                                ("{q}", v.query, true), ("{host}", v.host, false)]
        for (token, value, encode) in pairs where out.contains(token) {
            guard let value, !value.isEmpty else { return nil }
            out = out.replacingOccurrences(of: token, with: encode ? Text.encode(value) : value)
        }
        guard let u = URL(string: out) else { return nil }
        return u
    }

    // MARK: Extractors (public for tests)

    /// `spotify:track:<id>` -> id. Anything else (episodes, URLs, odd characters) -> nil.
    public static func spotifyTrackID(_ mediaId: String?) -> String? {
        guard let m = mediaId?.trimmingCharacters(in: .whitespaces), m.hasPrefix("spotify:track:") else { return nil }
        let id = String(m.dropFirst("spotify:track:".count))
        guard !id.isEmpty, id.count <= 40, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return id
    }

    /// Gmail's search: `subject:"<subject>"`. The subject is the first line of the text, or the title.
    public static func gmailSearch(title: String, text: String) -> String? {
        let firstLine = text.split(whereSeparator: \.isNewline).map { Text.collapse(String($0)) }.first { !$0.isEmpty } ?? ""
        var subject = firstLine.isEmpty ? Text.collapse(title) : firstLine
        subject = Text.shorten(subject.replacingOccurrences(of: "\"", with: ""), to: 150).trimmingCharacters(in: .whitespaces)
        guard !subject.isEmpty else { return nil }
        return "subject:\"\(subject)\""
    }

    /// The channel and video title for a YouTube search. The phone's notification puts the channel in one of
    /// title and text and the video in the other (or both in the text: "MKBHD uploaded: Title"); either way,
    /// searching for both finds the video. When nothing can be split out, the whole text is the query.
    public static func youtubeQuery(title: String, text: String) -> String? {
        var channel = Text.collapse(title)
        var video = Text.collapse(text)
        for prefix in ["new video from ", "new upload from ", "new video by ", "new upload by "] where channel.lowercased().hasPrefix(prefix) {
            channel = String(channel.dropFirst(prefix.count))
        }
        for suffix in [" is live", " is now live", " is premiering", " premiered"] where channel.lowercased().hasSuffix(suffix) {
            channel = String(channel.dropLast(suffix.count))
        }
        let verbs = "uploaded|posted|is live(?: now)?|is now live|went live|is premiering|premiered|started streaming"
        if let m = firstMatch("^(.+?)\\s+(?:\(verbs))\\s*[:\\-\u{2013}]?\\s*(.+)$", in: video), m.count == 2 {
            channel = m[0]; video = m[1]
        } else if let m = firstMatch("^(?:\(verbs))\\s*[:\\-\u{2013}]\\s*(.+)$", in: video), m.count == 1 {
            video = m[0]
        } else if let m = firstMatch("^(?:new(?: video| upload)?|live|now live|premiere|upload|streaming)\\s*[:\\-\u{2013}]\\s*(.+)$", in: video), m.count == 1 {
            video = m[0]
        }
        var parts: [String] = []
        for p in [channel, video] where !p.isEmpty {
            if parts.contains(where: { $0.caseInsensitiveCompare(p) == .orderedSame }) { continue }
            parts.append(p)
        }
        let q = Text.shorten(parts.joined(separator: " "), to: 120)
        return q.isEmpty ? nil : q
    }

    private static func firstMatch(_ pattern: String, in s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        var out: [String] = []
        for i in 1..<m.numberOfRanges {
            guard let r = Range(m.range(at: i), in: s) else { return nil }
            out.append(String(s[r]).trimmingCharacters(in: .whitespaces))
        }
        return out.contains(where: \.isEmpty) ? nil : out
    }
}

/// Small text helpers for building queries and URLs.
enum Text {
    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// Cuts at a word boundary when it can.
    static func shorten(_ s: String, to limit: Int) -> String {
        guard s.count > limit else { return s }
        let cut = String(s.prefix(limit))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return String(cut[..<space])
        }
        return cut
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Percent-encodes everything but unreserved characters, so it is safe in a query value or a fragment.
    static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
}

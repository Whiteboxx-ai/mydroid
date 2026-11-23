import Foundation

/// One message in a locally kept app-conversation history.
public struct HistoryMessage: Codable, Sendable, Equatable {
    public var sender: String      // "" for messages the user sent
    public var text: String
    public var when: Int64         // ms epoch
    /// Sent from this Mac and not yet seen in a notification from the phone.
    public var local: Bool?

    public init(sender: String, text: String, when: Int64, local: Bool? = nil) {
        self.sender = sender; self.text = text; self.when = when; self.local = local
    }
    public var isMine: Bool { sender.isEmpty }
    public var date: Date { Date(timeIntervalSince1970: Double(when) / 1000) }
}

public struct HistoryConversation: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var pkg: String
    public var app: String
    public var title: String
    public var isGroup: Bool
    public var avatar: Data?
    public var icon: Data?
    public var messages: [HistoryMessage]
    /// Key of the newest live notification for this conversation (used for reply and read sync).
    public var lastKey: String?

    public var last: HistoryMessage? { messages.last }
    public var updated: Date { last?.date ?? Date(timeIntervalSince1970: 0) }
}

/// What the phone has told us about app conversations (WhatsApp, Telegram, ...) through
/// `category:"message"` notifications, kept on this Mac. Android only ever sends the last few messages of a
/// conversation, so this grows as messages arrive. Capped per conversation, de-duplicated by sender, text and time.
public struct ConversationHistory: Codable, Sendable, Equatable {
    public static let cap = 200
    /// A reply sent from the Mac is matched to the phone's echo of it when the text is the same and the
    /// times are within this window.
    public static let localMatchWindow: Int64 = 5 * 60 * 1000

    public private(set) var conversations: [String: HistoryConversation] = [:]
    public init() {}

    public static func conversationID(pkg: String, title: String) -> String {
        pkg + "\u{1F}" + title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Adds what a message notification carries. Returns true when anything changed.
    @discardableResult
    public mutating func record(_ n: PhoneNotification) -> Bool {
        guard n.isMessage else { return false }
        let title = (n.conversation?.title).flatMap { $0.isEmpty ? nil : $0 } ?? (n.title.isEmpty ? n.displayApp : n.title)
        let id = Self.conversationID(pkg: n.pkg, title: title)
        var incoming: [HistoryMessage] = []
        if let c = n.conversation, !c.messages.isEmpty {
            incoming = c.messages.map { HistoryMessage(sender: $0.sender, text: $0.text, when: millis($0.when)) }
        } else if !n.text.isEmpty, !(n.conversation?.isGroup ?? false) {
            // Sparse payload (older phone build): the title is the other person.
            incoming = [HistoryMessage(sender: n.title, text: n.text, when: millis(n.when))]
        }
        // Verification codes are not worth keeping around.
        if n.otp != nil { incoming = [] }

        var conv = conversations[id] ?? HistoryConversation(id: id, pkg: n.pkg, app: n.displayApp, title: title,
                                                           isGroup: n.conversation?.isGroup ?? false,
                                                           avatar: nil, icon: nil, messages: [], lastKey: nil)
        let before = conv
        conv.app = n.displayApp
        if let g = n.conversation?.isGroup { conv.isGroup = g }
        if let a = n.conversation?.avatar, !a.isEmpty { conv.avatar = a }
        if let i = n.icon, !i.isEmpty { conv.icon = i }
        conv.lastKey = n.key
        for m in incoming { Self.merge(m, into: &conv.messages) }
        Self.trim(&conv.messages)
        if conv.messages.isEmpty && before.messages.isEmpty { return false }   // nothing to show yet
        conversations[id] = conv
        return conv != before
    }

    /// A reply typed on the Mac, shown right away.
    @discardableResult
    public mutating func addLocalReply(id: String, text: String, at date: Date = Date()) -> Bool {
        guard var conv = conversations[id], !text.isEmpty else { return false }
        conv.messages.append(HistoryMessage(sender: "", text: text, when: millis(date), local: true))
        Self.trim(&conv.messages)
        conversations[id] = conv
        return true
    }

    /// The notification is gone (read on the phone or here): the conversation stays, the key doesn't.
    public mutating func clearKey(_ key: String) {
        for (id, c) in conversations where c.lastKey == key { conversations[id]?.lastKey = nil }
    }

    public mutating func remove(_ id: String) { conversations[id] = nil }
    public mutating func replace(_ c: HistoryConversation) { conversations[c.id] = c }

    /// Newest conversation first.
    public func sorted() -> [HistoryConversation] {
        conversations.values.sorted { $0.updated > $1.updated }
    }

    private static func merge(_ m: HistoryMessage, into list: inout [HistoryMessage]) {
        if list.contains(where: { $0.sender == m.sender && $0.text == m.text && $0.when == m.when && $0.local != true }) { return }
        if m.isMine, let i = list.firstIndex(where: {
            $0.local == true && $0.text == m.text && abs($0.when - m.when) <= localMatchWindow
        }) {
            list.remove(at: i)
        }
        // Insert keeping time order (stable for equal times).
        let at = list.lastIndex(where: { $0.when <= m.when }).map { $0 + 1 } ?? 0
        list.insert(m, at: at)
    }

    private static func trim(_ list: inout [HistoryMessage]) {
        if list.count > cap { list.removeFirst(list.count - cap) }
    }

    // MARK: File

    public static func load(from url: URL) -> ConversationHistory {
        guard let d = try? Data(contentsOf: url), let h = try? JSONDecoder().decode(ConversationHistory.self, from: d) else {
            return ConversationHistory()
        }
        return h
    }

    public func save(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let d = try? JSONEncoder().encode(self) else { return }
        try? d.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

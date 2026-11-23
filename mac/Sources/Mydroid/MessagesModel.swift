import SwiftUI
import AppKit
import MydroidCore

enum ChatID: Hashable {
    case sms(String)
    /// `ConversationHistory.conversationID(pkg:title:)`
    case app(String)
}

enum SmsAvailability: Equatable {
    case off, loading, ready, needsPermission
    case failed(String)
}

/// One row in the conversation list.
struct ChatSummary: Identifiable, Equatable {
    var id: ChatID
    var title: String
    var snippet: String
    var date: Date
    var unread: Bool
    var avatar: Data?
    var isGroup: Bool
    /// Set for app conversations (WhatsApp, Telegram, ...).
    var appName: String?
    var appIcon: Data?
    var addresses: [String] = []
}

enum LineStatus: Equatable { case normal, pending, failed(String) }

/// One bubble in a thread.
struct ChatLine: Identifiable, Equatable {
    var id: String
    var sender: String
    var text: String
    var date: Date
    var isMine: Bool
    var status: LineStatus = .normal
    var isMMS = false
}

struct PendingSend: Identifiable, Equatable {
    enum State: Equatable { case sending, sent, failed(String) }
    var id: String               // clientId
    var threadId: String?
    var to: [String]
    var text: String
    var date: Date
    var state: State = .sending
}

/// Text messages (PROTOCOL.md 7.5) merged with app conversations built from message notifications (5.1),
/// plus read sync (7.6).
@MainActor @Observable
final class MessagesModel {
    static let smsPackages: Set<String> = [
        "com.google.android.apps.messaging", "com.android.mms", "com.samsung.android.messaging",
        "com.android.messaging", "com.oneplus.mms", "com.miui.mms", "com.coloros.mms",
    ]

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored let hub: Hub
    @ObservationIgnored private let historyURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var changedThreads: Set<String> = []
    @ObservationIgnored private var changeTask: Task<Void, Never>?
    @ObservationIgnored private var threadsTimeout: Task<Void, Never>?
    @ObservationIgnored private var requestKinds: [String: RequestKind] = [:]
    @ObservationIgnored private var pagedThreadsOnce = false
    @ObservationIgnored private(set) var lastThreadsFetch: Date?
    private enum RequestKind { case initial, older, refresh }

    // SMS
    var smsEnabled = false
    var threads: [SmsThread] = []
    var threadsMore = false
    var threadsLoading = false
    var threadsLoaded = false
    var permissionDenied = false
    var failure: String?
    var messagesByThread: [String: [SmsMessage]] = [:]
    var moreByThread: [String: Bool] = [:]
    var loadingThreads: Set<String> = []
    var pending: [PendingSend] = []
    /// Threads opened on this Mac: the dot stays off until a newer message arrives.
    var locallyRead: [String: Date] = [:]

    // App conversations
    var history = ConversationHistory()
    var live: [PhoneNotification] = []
    @ObservationIgnored private var lastRecordedLive: [PhoneNotification] = []

    // UI
    var selection: ChatID?
    var query = ""
    var composingNew = false
    var drafts: [ChatID: String] = [:]
    var sendError: [ChatID: String] = [:]
    var newRecipients = ""
    var newText = ""
    var newMessageError: String?

    /// Keys whose `notif.read` waits for the user to reply or leave (reading would remove the notification,
    /// and with it the ability to reply).
    @ObservationIgnored private var deferredReads: Set<String> = []

    init(hub: Hub, support: URL) {
        self.hub = hub
        historyURL = support.appendingPathComponent("history.json")
        history = ConversationHistory.load(from: historyURL)
    }

    // MARK: Derived

    var availability: SmsAvailability {
        if !smsEnabled { return .off }
        if permissionDenied { return .needsPermission }
        if let failure { return .failed(failure) }
        return threadsLoaded ? .ready : .loading
    }

    private var smsReady: Bool { availability == .ready }

    private func liveKey(for n: PhoneNotification) -> String {
        ConversationHistory.conversationID(pkg: n.pkg, title: Self.conversationTitle(n))
    }

    static func conversationTitle(_ n: PhoneNotification) -> String {
        if let t = n.conversation?.title, !t.isEmpty { return t }
        return n.title.isEmpty ? n.displayApp : n.title
    }

    func summaries() -> [ChatSummary] {
        var out: [ChatSummary] = []
        let liveByConv = Dictionary(live.map { (liveKey(for: $0), $0) }, uniquingKeysWith: { a, _ in a })
        if smsReady || !threads.isEmpty {
            for t in threads {
                let unread = t.unread > 0 && !(locallyRead[t.id.text].map { $0 >= t.date } ?? false)
                out.append(ChatSummary(id: .sms(t.id.text), title: t.name.isEmpty ? (t.addresses.first ?? "Unknown") : t.name,
                                       snippet: t.snippet, date: t.date, unread: unread, avatar: t.avatar, isGroup: t.isGroup,
                                       addresses: t.addresses))
            }
        }
        var seen = Set<String>()
        for c in history.sorted() {
            if smsReady, Self.smsPackages.contains(c.pkg) { continue }
            seen.insert(c.id)
            let liveN = liveByConv[c.id]
            out.append(ChatSummary(id: .app(c.id), title: c.title, snippet: Self.snippet(c.last, group: c.isGroup),
                                   date: c.updated, unread: liveN != nil && !(unreadCleared.contains(liveN!.key)), avatar: c.avatar,
                                   isGroup: c.isGroup, appName: c.app, appIcon: c.icon))
        }
        // Live conversations that carry no message text we could keep.
        for n in live where !seen.contains(liveKey(for: n)) && !(smsReady && Self.smsPackages.contains(n.pkg)) {
            guard let conv = n.effectiveConversation else { continue }
            out.append(ChatSummary(id: .app(liveKey(for: n)), title: conv.title, snippet: Self.snippet(conv.last.map {
                HistoryMessage(sender: $0.sender, text: $0.text, when: Int64($0.when.timeIntervalSince1970 * 1000))
            }, group: conv.isGroup), date: conv.last?.when ?? n.when, unread: true, avatar: conv.avatar, isGroup: conv.isGroup,
                                   appName: n.displayApp, appIcon: n.icon))
        }
        out.sort { $0.date > $1.date }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return out }
        return out.filter { matches($0, q) }
    }

    /// Opened here but the phone hasn't removed the notification yet.
    var unreadCleared: Set<String> = []

    private func matches(_ c: ChatSummary, _ q: String) -> Bool {
        func has(_ s: String) -> Bool { s.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        if has(c.title) || has(c.snippet) || c.addresses.contains(where: has) { return true }
        switch c.id {
        case let .sms(t): return (messagesByThread[t] ?? []).contains { has($0.body) }
        case let .app(a): return (history.conversations[a]?.messages ?? []).contains { has($0.text) }
        }
    }

    var unreadCount: Int { summaries().filter(\.unread).count }

    static func snippet(_ m: HistoryMessage?, group: Bool) -> String {
        guard let m else { return "" }
        if m.isMine { return "You: \(m.text)" }
        return group && !m.sender.isEmpty ? "\(m.sender): \(m.text)" : m.text
    }

    func summary(for id: ChatID) -> ChatSummary? { summaries().first { $0.id == id } }

    func thread(_ id: String) -> SmsThread? { threads.first { $0.id.text == id } }

    /// A contact name for a number when some thread with only that number has one.
    func displayName(forAddress a: String) -> String {
        let d = Self.digits(a)
        guard !d.isEmpty else { return a }
        if let t = threads.first(where: { $0.addresses.count == 1 && Self.digits($0.addresses[0]) == d }), !t.name.isEmpty { return t.name }
        return a
    }

    func lines(for id: ChatID) -> [ChatLine] {
        switch id {
        case let .sms(tid):
            var out = (messagesByThread[tid] ?? []).map { m in
                ChatLine(id: "m\(m.id.text)", sender: m.out ? "" : displayName(forAddress: m.from), text: m.body, date: m.date, isMine: m.out,
                         status: m.status == .pending ? .pending : (m.status == .failed ? .failed("Not delivered") : .normal), isMMS: m.mms)
            }
            let known = Set(out.map(\.text))
            for p in pending where p.threadId == tid {
                if p.state == .sent, known.contains(p.text), out.contains(where: { $0.isMine && $0.text == p.text && $0.date >= p.date.addingTimeInterval(-90) }) { continue }
                out.append(ChatLine(id: "p\(p.id)", sender: "", text: p.text, date: p.date, isMine: true,
                                    status: { if case let .failed(e) = p.state { return .failed(e) }; return p.state == .sending ? .pending : .normal }()))
            }
            return out.sorted { $0.date < $1.date }
        case let .app(cid):
            if let c = history.conversations[cid] {
                return c.messages.enumerated().map { i, m in
                    ChatLine(id: "h\(i)-\(m.when)", sender: m.sender, text: m.text, date: m.date, isMine: m.isMine,
                             status: m.local == true && (app?.replyStatus[c.lastKey ?? ""] == .sending) ? .pending : .normal)
                }
            }
            if let n = live.first(where: { liveKey(for: $0) == cid }), let conv = n.effectiveConversation {
                return conv.messages.enumerated().map { i, m in
                    ChatLine(id: "l\(i)", sender: m.sender, text: m.text, date: m.when, isMine: m.isMine)
                }
            }
            return []
        }
    }

    func isGroup(_ id: ChatID) -> Bool { summary(for: id)?.isGroup ?? false }

    /// The live notification that can carry a reply for this app conversation.
    func replyTarget(for id: ChatID) -> PhoneNotification? {
        guard case let .app(cid) = id else { return nil }
        return live.first { liveKey(for: $0) == cid && $0.canReply }
    }

    // MARK: Phone -> model

    func update(notifications: [PhoneNotification], smsEnabled: Bool, connected: Bool) {
        let wasEnabled = self.smsEnabled
        self.smsEnabled = smsEnabled
        let msgs = notifications.filter(\.isMessage).sorted { $0.when > $1.when }
        if msgs != lastRecordedLive {
            lastRecordedLive = msgs
            var changed = false
            for n in msgs { if history.record(n) { changed = true } }
            if changed { scheduleSave() }
            live = msgs
            let keys = Set(msgs.map(\.key))
            unreadCleared.formIntersection(keys)
            deferredReads.formIntersection(keys)
        }
        if smsEnabled && !wasEnabled && connected { refreshThreads(force: true) }
    }

    func handle(_ e: HubEvent) {
        switch e {
        case let .smsThreads(new, req): applyThreads(new, req)
        case let .smsMessages(tid, msgs): applyMessages(tid.text, msgs)
        case let .smsSent(s): applySent(s)
        case let .smsChanged(tid): noteChanged(tid.text)
        case let .smsError(err, req):
            loadingThreads.removeAll()
            if req == "sms.send" {
                for i in pending.indices where pending[i].state == .sending {
                    pending[i].state = .failed(err == "permission" ? "Your phone needs permission to send texts" : "Your phone couldn't send it")
                }
            } else if req != "sms.messages.get" {
                threadsLoading = false
            }
            if err == "permission" { permissionDenied = true }
            else if req == nil || req == "sms.threads.get" { failure = "Your phone couldn't read its messages." }
        case .sessionReady:
            if smsEnabled && threadsLoaded { refreshThreads(force: true) }
        case .sessionClosed:
            threadsLoading = false
            loadingThreads.removeAll()
            for i in pending.indices where pending[i].state == .sending { pending[i].state = .failed("Your phone disconnected") }
        default: break
        }
    }

    private func applyThreads(_ new: [SmsThread], _ req: SmsThreadsRequest?) {
        threadsLoading = false
        threadsTimeout?.cancel()
        threadsLoaded = true
        permissionDenied = false
        failure = nil
        var map: [String: SmsThread] = [:]
        for t in threads { map[t.id.text] = t }
        for t in new { map[t.id.text] = t }
        threads = map.values.sorted { $0.date > $1.date }
        if let req {
            if req.before != nil { threadsMore = new.count >= req.limit }
            else if !pagedThreadsOnce { threadsMore = new.count >= req.limit }
        }
    }

    private func applyMessages(_ tid: String, _ msgs: [SmsMessage]) {
        loadingThreads.remove(tid)
        var map: [WireID: SmsMessage] = [:]
        for m in messagesByThread[tid] ?? [] { map[m.id] = m }
        for m in msgs { map[m.id] = m }
        messagesByThread[tid] = map.values.sorted { $0.date < $1.date }
        let kind = requestKinds.removeValue(forKey: tid) ?? .refresh
        if kind != .refresh { moreByThread[tid] = msgs.count >= 50 }
        // A sent bubble is replaced by the phone's copy once that shows up.
        pending.removeAll { p in
            p.threadId == tid && p.state == .sent && msgs.contains { $0.out && $0.body == p.text && $0.date >= p.date.addingTimeInterval(-90) }
        }
    }

    private func applySent(_ s: SmsSent) {
        guard let i = pending.firstIndex(where: { $0.id == s.clientId }) else { return }
        if s.ok {
            pending[i].state = .sent
            if pending[i].threadId == nil, let t = s.threadId?.text {
                pending[i].threadId = t
                if composingNew { composingNew = false; selection = .sms(t); newText = ""; newRecipients = "" }
            }
            let p = pending[i]
            if let t = p.threadId, let wid = threadWireID(t) {
                hub.requestSmsMessages(threadId: wid, limit: 50)
                refreshThreads(force: true)
                // The phone's copy can lag a moment behind its own `sms.sent`.
                Task { [weak self] in
                    for delay in [1.2, 3.0] {
                        try? await Task.sleep(for: .seconds(delay))
                        guard let self, self.pending.contains(where: { $0.id == p.id }) else { return }
                        self.hub.requestSmsMessages(threadId: wid, limit: 50)
                    }
                    try? await Task.sleep(for: .seconds(4))
                    self?.pending.removeAll { $0.id == p.id && $0.state == .sent }
                }
            }
        } else {
            pending[i].state = .failed(Self.friendlySendError(s.error))
        }
    }

    static func friendlySendError(_ e: String?) -> String {
        switch e {
        case nil, "": return "Your phone couldn't send it"
        case "permission": return "Your phone needs permission to send texts"
        default: return e!
        }
    }

    private func threadWireID(_ text: String) -> WireID? {
        threads.first { $0.id.text == text }?.id ?? messagesByThread[text]?.first.map { _ in WireID(text, numeric: Int64(text) != nil) } ?? WireID(text, numeric: Int64(text) != nil)
    }

    private func noteChanged(_ tid: String) {
        guard smsEnabled else { return }
        changedThreads.insert(tid)
        changeTask?.cancel()
        changeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            let ids = self.changedThreads
            self.changedThreads = []
            self.refreshThreads(force: true)
            for t in ids where self.messagesByThread[t] != nil || self.selection == .sms(t) {
                if let w = self.threadWireID(t) { self.requestMessages(w, kind: .refresh) }
            }
        }
    }

    // MARK: Requests

    /// Loads the first page, or refreshes it.
    func refreshThreads(force: Bool = false) {
        guard smsEnabled, app?.state.link == .connected else { return }
        if !force, threadsLoaded, let t = lastThreadsFetch, Date().timeIntervalSince(t) < 30 { return }
        lastThreadsFetch = Date()
        if !threadsLoaded { threadsLoading = true }
        hub.requestSmsThreads(limit: 50, before: nil)
        armThreadsTimeout()
    }

    func loadMoreThreads() {
        guard smsEnabled, threadsMore, !threadsLoading, let oldest = threads.last?.date, app?.state.link == .connected else { return }
        threadsLoading = true
        pagedThreadsOnce = true
        hub.requestSmsThreads(limit: 50, before: oldest)
        armThreadsTimeout()
    }

    private func armThreadsTimeout() {
        threadsTimeout?.cancel()
        threadsTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.threadsLoading else { return }
            self.threadsLoading = false
            if !self.threadsLoaded { self.failure = "Your phone didn't answer." }
        }
    }

    func retryAfterFailure() { failure = nil; permissionDenied = false; refreshThreads(force: true) }

    private func requestMessages(_ tid: WireID, kind: RequestKind, before: Date? = nil) {
        requestKinds[tid.text] = kind
        if kind != .refresh { loadingThreads.insert(tid.text) }
        hub.requestSmsMessages(threadId: tid, limit: 50, before: before)
        let id = tid.text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            self?.loadingThreads.remove(id)
        }
    }

    func loadOlder(_ id: ChatID) {
        guard case let .sms(tid) = id, moreByThread[tid] ?? false, !loadingThreads.contains(tid),
              let oldest = messagesByThread[tid]?.first?.date, let w = threadWireID(tid) else { return }
        requestMessages(w, kind: .older, before: oldest)
    }

    func enableSms() {
        app?.updateSettings { $0.smsHistory = true }
        smsEnabled = true
        permissionDenied = false
        failure = nil
        refreshThreads(force: true)
    }

    func askForPermission() { app?.fix(.sms) }

    // MARK: Opening, read sync

    func open(_ id: ChatID?) {
        if let old = selection, old != id { closed(old) }
        composingNew = false
        selection = id
        guard let id else { return }
        sendError[id] = nil
        switch id {
        case let .sms(tid):
            if let t = thread(tid) { locallyRead[tid] = t.date }
            if messagesByThread[tid] == nil, let w = threadWireID(tid) { requestMessages(w, kind: .initial) }
            else if let w = threadWireID(tid) { requestMessages(w, kind: .refresh) }
            for k in smsNotificationKeys(tid) { markRead(key: k, canReply: false) }
        case let .app(cid):
            for n in live where liveKey(for: n) == cid { markRead(key: n.key, canReply: n.canReply) }
        }
    }

    func startNewMessage() {
        if let old = selection { closed(old) }
        selection = nil
        composingNew = true
        newMessageError = nil
    }

    /// Leaving a conversation fires any read that was waiting.
    func closed(_ id: ChatID) {
        guard case let .app(cid) = id else { return }
        for n in live where liveKey(for: n) == cid { flushRead(n.key) }
    }

    func windowClosed() {
        if let s = selection { closed(s) }
    }

    func smsNotificationKeys(_ tid: String) -> [String] {
        guard let t = thread(tid) else { return [] }
        let names = Set(([t.name] + t.addresses).map { $0.lowercased() })
        let digs = Set(t.addresses.map(Self.digits).filter { !$0.isEmpty })
        return live.filter { n in
            guard Self.smsPackages.contains(n.pkg) else { return false }
            let title = Self.conversationTitle(n)
            return names.contains(title.lowercased()) || digs.contains(Self.digits(title)) && !Self.digits(title).isEmpty
        }.map(\.key)
    }

    /// `notif.read`. A conversation that can be replied to keeps its notification until the user replies or leaves,
    /// because Android needs the notification to deliver the reply.
    func markRead(key: String, canReply: Bool) {
        unreadCleared.insert(key)
        if canReply { deferredReads.insert(key) } else { hub.markRead(key: key) }
    }

    func flushRead(_ key: String) {
        if deferredReads.remove(key) != nil { hub.markRead(key: key) }
    }

    /// The conversation was opened somewhere else (its app on the Mac, the web, the phone): that counts as reading it.
    func readElsewhere(key: String) {
        deferredReads.remove(key)
        unreadCleared.insert(key)
        hub.markRead(key: key)
    }

    /// The reply went out: now it is fine to mark the conversation read.
    func replySucceeded(key: String) {
        deferredReads.remove(key)
        unreadCleared.insert(key)
        hub.markRead(key: key)
        history.clearKey(key)
    }

    // MARK: Sending

    func draft(_ id: ChatID) -> String { drafts[id] ?? "" }
    func setDraft(_ id: ChatID, _ t: String) { drafts[id] = t }

    func send(in id: ChatID, text raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard app?.state.link == .connected else { sendError[id] = "Your phone isn't connected."; return }
        sendError[id] = nil
        switch id {
        case let .sms(tid):
            guard let t = thread(tid) else { return }
            submit(to: t.addresses, text: text, threadId: tid)
            drafts[id] = ""
        case let .app(cid):
            guard let n = replyTarget(for: id) else {
                sendError[id] = "Reply after the next message arrives"
                return
            }
            history.addLocalReply(id: cid, text: text)
            scheduleSave()
            replyDraftBackup[n.key] = text
            drafts[id] = ""
            app?.reply(to: n, text: text)
        }
    }

    @ObservationIgnored private var replyDraftBackup: [String: String] = [:]

    /// `notif.result` for a reply sent from a conversation here.
    func replyResult(key: String, ok: Bool, error: String?) {
        guard let text = replyDraftBackup.removeValue(forKey: key) else { return }
        if ok { replySucceeded(key: key); return }
        // Take the local bubble back and give the text back to the composer.
        for (cid, var c) in history.conversations where c.lastKey == key {
            if let i = c.messages.lastIndex(where: { $0.local == true && $0.text == text }) {
                c.messages.remove(at: i)
                history.replace(c)
            }
            drafts[.app(cid)] = text
            sendError[.app(cid)] = "Couldn't send. \(error ?? "Your phone couldn't send it")"
        }
        scheduleSave()
    }

    func submit(to addresses: [String], text: String, threadId: String?) {
        let wid = threadId.flatMap(threadWireID)
        let clientId = hub.sendSms(to: addresses, text: text, threadId: wid)
        pending.append(PendingSend(id: clientId, threadId: threadId, to: addresses, text: text, date: Date()))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, let i = self.pending.firstIndex(where: { $0.id == clientId }), self.pending[i].state == .sending else { return }
            self.pending[i].state = .failed("No answer from your phone")
        }
    }

    func retry(_ lineID: String, in id: ChatID) {
        guard lineID.hasPrefix("p"), let p = pending.first(where: { "p\($0.id)" == lineID }) else { return }
        pending.removeAll { $0.id == p.id }
        submit(to: p.to, text: p.text, threadId: p.threadId)
    }

    func discard(_ lineID: String) { pending.removeAll { "p\($0.id)" == lineID } }

    /// Resolves what was typed in the "To:" field to phone numbers.
    func resolveRecipients(_ text: String) -> [String]? {
        let parts = text.split(whereSeparator: { ",;\n".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        var out: [String] = []
        for p in parts {
            if Self.looksLikeNumber(p) { out.append(p); continue }
            let matches = threads.filter { !$0.isGroup && $0.name.range(of: p, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            guard matches.count >= 1, let a = matches.first?.addresses.first else { return nil }
            out.append(a)
        }
        return out
    }

    func recipientSuggestions(for text: String) -> [SmsThread] {
        let last = text.split(separator: ",", omittingEmptySubsequences: false).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !last.isEmpty else { return Array(threads.filter { !$0.isGroup }.prefix(5)) }
        return Array(threads.filter { t in
            !t.isGroup && (t.name.range(of: last, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                           || t.addresses.contains { Self.digits($0).contains(Self.digits(last)) && !Self.digits(last).isEmpty })
        }.prefix(5))
    }

    func sendNew() {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard app?.state.link == .connected else { newMessageError = "Your phone isn't connected."; return }
        guard let to = resolveRecipients(newRecipients) else {
            newMessageError = "Enter a number or a name"
            return
        }
        newMessageError = nil
        // An existing conversation with the same people.
        let key = Set(to.map(Self.digits))
        if let t = threads.first(where: { Set($0.addresses.map(Self.digits)) == key }) {
            composingNew = false
            let id = ChatID.sms(t.id.text)
            open(id)
            submit(to: to, text: text, threadId: t.id.text)
            newText = ""; newRecipients = ""
            return
        }
        submit(to: to, text: text, threadId: nil)
        // Selection moves to the new thread when `sms.sent` names it.
    }

    // MARK: Helpers

    static func digits(_ s: String) -> String {
        let d = s.filter(\.isNumber)
        return d.count > 10 ? String(d.suffix(10)) : d
    }

    static func looksLikeNumber(_ s: String) -> Bool {
        let allowed = Set("+()-. 0123456789*#")
        return s.filter(\.isNumber).count >= 3 && s.allSatisfy { allowed.contains($0) }
    }

    // MARK: History persistence

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = history
        let url = historyURL
        saveTask = Task.detached {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            snapshot.save(to: url)
        }
    }

    func flushSave() { saveTask?.cancel(); history.save(to: historyURL) }
}

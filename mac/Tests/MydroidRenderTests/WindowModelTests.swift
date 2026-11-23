import XCTest
@testable import Mydroid
@testable import MydroidCore

/// Logic behind the full window, driven with fixture data and no phone.
@MainActor
final class WindowModelTests: XCTestCase {
    private func model(sms: Bool = true) -> AppModel {
        var st = HubState()
        st.link = .connected
        st.phone = PhoneInfo(name: "Pixel 9")
        st.settings.smsHistory = sms
        return AppModel(fixture: st)
    }

    private func notif(_ key: String, pkg: String, title: String, text: String = "hi", canReply: Bool = true, group: Bool = false,
                       msgs: [(String, String)]? = nil) -> PhoneNotification {
        let now = Date()
        let list = (msgs ?? [(title, text)]).enumerated().map { ConversationMessage(sender: $1.0, text: $1.1, when: now.addingTimeInterval(Double($0) - 10)) }
        return PhoneNotification(key: key, pkg: pkg, app: AppNames.present(pkg), title: title, text: text, when: now, canReply: canReply, category: .message,
                                 conversation: Conversation(title: title, isGroup: group, messages: list))
    }

    func testListMergesTextsWithAppChatsAndHidesDuplicateSmsNotifications() {
        let m = model()
        let ms = m.messages
        ms.threadsLoaded = true
        ms.threads = [SmsThread(id: "1", addresses: ["+1555"], name: "Maya", snippet: "coffee?", date: Date().addingTimeInterval(-60), unread: 1)]
        let wa = notif("wa", pkg: "com.whatsapp", title: "Goa trip", group: true, msgs: [("Dev", "booking"), ("", "nice")])
        let sms = notif("sms", pkg: "com.google.android.apps.messaging", title: "Maya", text: "coffee?")
        ms.update(notifications: [wa, sms], smsEnabled: true, connected: true)
        let rows = ms.summaries()
        XCTAssertEqual(rows.map(\.title), ["Goa trip", "Maya"], "newest first; the Messages-app notification is not a second Maya")
        XCTAssertEqual(rows[0].appName, "WhatsApp")
        XCTAssertNil(rows[1].appName)
        XCTAssertTrue(rows[0].unread, "a live notification means unread")
        XCTAssertTrue(rows[1].unread)
        XCTAssertEqual(rows[0].snippet, "You: nice")
        // With texts unavailable the same notification is shown as an app conversation.
        ms.threads = []; ms.threadsLoaded = false; ms.permissionDenied = true
        XCTAssertEqual(ms.availability, .needsPermission)
        XCTAssertEqual(Set(ms.summaries().map(\.title)), ["Goa trip", "Maya"])
        ms.query = "booking"
        XCTAssertEqual(ms.summaries().map(\.title), ["Goa trip"], "search looks inside messages")
    }

    func testReadSyncWaitsForRepliesButNotForPlainConversations() {
        let m = model()
        let ms = m.messages
        let wa = notif("wa", pkg: "com.whatsapp", title: "Rohan", canReply: true)
        let plain = notif("plain", pkg: "com.slack", title: "#general", canReply: false)
        ms.update(notifications: [wa, plain], smsEnabled: false, connected: true)
        let waID = ChatID.app(ConversationHistory.conversationID(pkg: "com.whatsapp", title: "Rohan"))
        let plainID = ChatID.app(ConversationHistory.conversationID(pkg: "com.slack", title: "#general"))
        ms.open(plainID)
        XCTAssertTrue(ms.unreadCleared.contains("plain"), "the dot clears right away")
        ms.open(waID)
        XCTAssertTrue(ms.unreadCleared.contains("wa"))
        XCTAssertNotNil(ms.replyTarget(for: waID), "still repliable: the notification wasn't read away yet")
        ms.open(nil)   // leaving fires the waiting read
        XCTAssertFalse(ms.summaries().contains { $0.id == waID && $0.unread })
    }

    func testSendingTextFlow() {
        let m = model()
        let ms = m.messages
        ms.threadsLoaded = true
        ms.threads = [SmsThread(id: WireID("5", numeric: true), addresses: ["+1555"], name: "Maya", snippet: "", date: Date())]
        ms.send(in: .sms("5"), text: "  on my way  ")
        XCTAssertEqual(ms.pending.count, 1)
        XCTAssertEqual(ms.pending[0].text, "on my way")
        XCTAssertEqual(ms.lines(for: .sms("5")).map(\.status), [.pending], "an optimistic bubble")
        let cid = ms.pending[0].id
        ms.handle(.smsSent(SmsSent(clientId: cid, ok: true, error: nil, threadId: WireID("5", numeric: true))))
        XCTAssertEqual(ms.pending[0].state, .sent)
        XCTAssertEqual(ms.lines(for: .sms("5")).map(\.status), [.normal])
        // The phone's own copy replaces it.
        ms.handle(.smsMessages(threadId: WireID("5", numeric: true), messages: [SmsMessage(id: "9", body: "on my way", date: Date(), out: true, status: .sent)]))
        XCTAssertTrue(ms.pending.isEmpty)
        XCTAssertEqual(ms.lines(for: .sms("5")).count, 1)
        // A failure keeps the bubble, marked.
        ms.send(in: .sms("5"), text: "again")
        ms.handle(.smsSent(SmsSent(clientId: ms.pending[0].id, ok: false, error: "no service", threadId: nil)))
        XCTAssertEqual(ms.lines(for: .sms("5")).last?.status, .failed("no service"))
        ms.send(in: .sms("5"), text: "  ")
        XCTAssertEqual(ms.pending.count, 1, "blank messages are not sent")
        // The phone refusing to send (no SEND_SMS) fails what is waiting, and asks for permission.
        ms.send(in: .sms("5"), text: "third")
        ms.handle(.smsError("permission", request: "sms.send"))
        XCTAssertEqual(ms.pending.filter { $0.state == .sending }.count, 0)
        XCTAssertEqual(ms.availability, .needsPermission)
        ms.handle(.smsThreads([SmsThread(id: "5", addresses: ["+1555"], name: "Maya", date: Date())], request: nil))
        XCTAssertEqual(ms.availability, .ready, "a good answer clears it")
    }

    func testRecipients() {
        let m = model()
        let ms = m.messages
        ms.threads = [SmsThread(id: "1", addresses: ["+15551230001"], name: "Maya Tan", date: Date()),
                      SmsThread(id: "2", addresses: ["+15551230002", "+15551230003"], name: "Hike", date: Date())]
        XCTAssertEqual(ms.resolveRecipients("+1 (555) 123-0009"), ["+1 (555) 123-0009"])
        XCTAssertEqual(ms.resolveRecipients("maya"), ["+15551230001"])
        XCTAssertEqual(ms.resolveRecipients("maya, 555 123 0044"), ["+15551230001", "555 123 0044"])
        XCTAssertNil(ms.resolveRecipients("nobody"))
        XCTAssertNil(ms.resolveRecipients("hike"), "groups aren't recipients")
        XCTAssertNil(ms.resolveRecipients("  "))
        XCTAssertEqual(ms.recipientSuggestions(for: "ma").map(\.name), ["Maya Tan"])
        XCTAssertTrue(MessagesModel.looksLikeNumber("+91 98765-43210"))
        XCTAssertFalse(MessagesModel.looksLikeNumber("12"))
        XCTAssertFalse(MessagesModel.looksLikeNumber("abc123456"))
    }

    func testPhotosMonthsAndSelection() {
        let m = model()
        let p = m.photos
        let cal = Calendar.current
        func d(_ y: Int, _ mo: Int, _ day: Int) -> Date { cal.date(from: DateComponents(year: y, month: mo, day: day, hour: 12))! }
        let items = [PhotoItem(id: "4", name: "d", taken: d(2026, 11, 20)), PhotoItem(id: "3", name: "c", taken: d(2026, 11, 2)),
                     PhotoItem(id: "2", name: "b", taken: d(2026, 10, 30)), PhotoItem(id: "1", name: "a", taken: d(2025, 12, 1))]
        p.albums[.all] = AlbumState(items: items, more: false, loading: false, loaded: true)
        XCTAssertEqual(p.months(of: p.items).map { $0.items.count }, [2, 1, 1])
        p.click(items[0], command: false, shift: false)
        p.click(items[2], command: false, shift: true)
        XCTAssertEqual(p.selection, ["4", "3", "2"], "shift selects the range")
        p.click(items[1], command: true, shift: false)
        XCTAssertEqual(p.selection, ["4", "2"], "command toggles")
        p.click(items[3], command: false, shift: false)
        XCTAssertEqual(p.selection, ["1"])
        // Pages merge without duplicates and keep newest first.
        p.handle(.photosPage(PhotosPage(album: .all, before: nil, items: [items[1], PhotoItem(id: "5", name: "e", taken: d(2026, 11, 22))], more: true)))
        XCTAssertEqual(p.items.map { $0.id.text }, ["5", "4", "3", "2", "1"])
        XCTAssertTrue(p.current.more)
    }

    func testFilesListOrdersAndFilters() {
        let m = model()
        let f = m.files
        let now = Date()
        f.received = [SavedFile(xid: "photo:1", kind: "photo", url: URL(fileURLWithPath: "/tmp/a.jpg"), name: "a.jpg", size: 1, taken: now.addingTimeInterval(-100), savedAt: now),
                      SavedFile(xid: "file:2", kind: "file", url: URL(fileURLWithPath: "/tmp/b.pdf"), name: "b.pdf", size: 1, taken: nil, savedAt: now.addingTimeInterval(-50))]
        f.sent = [SentRecord(xid: "file:3", name: "c.zip", size: 1, date: now.addingTimeInterval(-10), path: nil, failed: nil)]
        f.active = [TransferProgress(xid: "file:4", name: "d.key", kind: "file", outgoing: true, done: 1, total: 4)]
        XCTAssertEqual(f.entries.map(\.name), ["d.key", "c.zip", "b.pdf", "a.jpg"], "in-flight first, then newest")
        f.filter = .photos; XCTAssertEqual(f.entries.map(\.name), ["a.jpg"])
        f.filter = .files; XCTAssertEqual(f.entries.map(\.name), ["b.pdf"])
        f.filter = .sent; XCTAssertEqual(f.entries.map(\.name), ["d.key", "c.zip"])
        // Library downloads never show up here; the Hub keeps them out of the ledger.
        f.handle(.sent(xid: "file:3", name: "c.zip", skipped: false))
        XCTAssertEqual(f.sent.count, 1, "a finished send replaces its own record")
    }

    func testCallsFilterAndDialNote() {
        let m = model()
        let c = m.calls
        c.records = [CallRecord(number: "1", kind: .missed, date: Date()), CallRecord(number: "2", kind: .incoming, date: Date().addingTimeInterval(-5)),
                     CallRecord(number: "3", kind: .rejected, date: Date().addingTimeInterval(-9))]
        c.filter = .missed
        XCTAssertEqual(c.visible.map(\.number), ["1", "3"])
        c.press("5"); c.press("5"); c.backspace()
        XCTAssertEqual(c.number, "5")
        c.dial("  ")
        XCTAssertNil(c.note)
        c.dial("*#06#")
        XCTAssertNil(c.note, "codes are refused, as the phone would")
        XCTAssertNotNil(CallsModel.problem(with: "*123#"))
        XCTAssertNotNil(CallsModel.problem(with: "12"))
        XCTAssertNotNil(CallsModel.problem(with: "55+5123"))
        XCTAssertNotNil(CallsModel.problem(with: "abc"))
        XCTAssertNil(CallsModel.problem(with: "+91 (987) 654-3210"))
        c.dial("+1 555 0100")
        XCTAssertEqual(c.note, "Calling on your phone")
    }
}

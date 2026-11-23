import XCTest
import CryptoKit
@testable import MydroidCore

/// A message as it arrives over the wire: encoded and decoded again, so JSON numbers come back as NSNumber.
private func wire(_ type: String, _ fields: [String: Any], payload: Data = Data()) throws -> Message {
    try Message.decode(try Message(type, fields, payload: payload).encode())
}

final class SmsDecoderTests: XCTestCase {
    func testWireIDKeepsNumberOrString() throws {
        let m = try wire("x", ["n": 42, "s": "abc", "b": true, "big": 9_007_199_254_740_000, "empty": ""])
        let n = try XCTUnwrap(WireID(any: m.fields["n"]))
        XCTAssertEqual(n.text, "42"); XCTAssertTrue(n.numeric)
        XCTAssertEqual(n.json as? Int64, 42)
        let s = try XCTUnwrap(WireID(any: m.fields["s"]))
        XCTAssertEqual(s.text, "abc"); XCTAssertFalse(s.numeric)
        XCTAssertEqual(s.json as? String, "abc")
        XCTAssertNil(WireID(any: m.fields["b"]), "a bool is not an id")
        XCTAssertNil(WireID(any: m.fields["empty"]))
        XCTAssertNil(WireID(any: nil))
        XCTAssertEqual(WireID(any: m.fields["big"])?.text, "9007199254740000")
    }

    func testThreads() throws {
        let m = try wire("sms.threads", ["threads": [
            ["threadId": 7, "addresses": ["+15551230001"], "name": "Maya Tan", "snippet": "coffee?", "date": 1_700_000_000_000, "unread": 2,
             "avatar": Data([1, 2, 3]).base64EncodedString()],
            ["threadId": "t8", "addresses": ["+15551230002", "+15551230003"], "name": "", "snippet": "", "date": 1_700_000_100_000, "unread": 0],
            ["addresses": ["no id"]],
        ]])
        let t = SmsDecode.threads(m)
        XCTAssertEqual(t.count, 2, "a thread without an id is dropped")
        XCTAssertEqual(t[0].id.text, "7"); XCTAssertTrue(t[0].id.numeric)
        XCTAssertEqual(t[0].name, "Maya Tan")
        XCTAssertEqual(t[0].unread, 2)
        XCTAssertEqual(t[0].date, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(t[0].avatar, Data([1, 2, 3]))
        XCTAssertFalse(t[0].isGroup)
        XCTAssertEqual(t[1].id.text, "t8")
        XCTAssertEqual(t[1].name, "+15551230002", "an empty name falls back to the first address")
        XCTAssertTrue(t[1].isGroup)
        XCTAssertNil(t[1].avatar)
    }

    func testMessages() throws {
        let m = try wire("sms.messages", ["threadId": 7, "messages": [
            ["id": 1, "from": "+15551230001", "body": "hi", "date": 1_700_000_000_000, "out": false, "status": "received"],
            ["id": 2, "from": "", "body": "hello", "date": 1_700_000_001_000, "out": true, "status": "pending"],
            ["id": 3, "from": "", "body": "[Photo]", "date": 1_700_000_002_000, "out": true, "status": "sent", "mms": true],
            ["id": 4, "from": "", "body": "x", "date": 1_700_000_003_000, "out": true, "status": "failed"],
            ["id": 5, "body": "no date"],
        ]])
        let r = try XCTUnwrap(SmsDecode.messages(m))
        XCTAssertEqual(r.threadId.text, "7")
        XCTAssertEqual(r.messages.map(\.status), [.received, .pending, .sent, .failed])
        XCTAssertEqual(r.messages.map(\.out), [false, true, true, true])
        XCTAssertTrue(r.messages[2].mms)
        XCTAssertFalse(r.messages[0].mms)
        XCTAssertEqual(r.messages[1].body, "hello")
        XCTAssertNil(SmsDecode.messages(try wire("sms.messages", ["messages": [Any]()])), "needs a threadId")
        // Missing id and unknown status still decode.
        let lenient = SmsMessage(fields: ["body": "b", "date": 1_700_000_000_000, "out": true, "status": "weird"])
        XCTAssertEqual(lenient?.status, .sent)
        XCTAssertEqual(SmsMessage(fields: ["body": "b", "date": 1_700_000_000_000, "out": false])?.status, .received)
    }

    func testSentChangedAndError() throws {
        let ok = try XCTUnwrap(SmsDecode.sent(try wire("sms.sent", ["clientId": "c1", "ok": true, "threadId": 9])))
        XCTAssertEqual(ok, SmsSent(clientId: "c1", ok: true, error: nil, threadId: WireID("9", numeric: true)))
        let bad = try XCTUnwrap(SmsDecode.sent(try wire("sms.sent", ["clientId": "c2", "ok": false, "error": "no service"])))
        XCTAssertFalse(bad.ok); XCTAssertEqual(bad.error, "no service"); XCTAssertNil(bad.threadId)
        XCTAssertNil(SmsDecode.sent(try wire("sms.sent", ["ok": true])))
        XCTAssertEqual(SmsDecode.changed(try wire("sms.changed", ["threadId": "abc"]))?.text, "abc")
        XCTAssertNil(SmsDecode.changed(try wire("sms.changed", [:])))
    }
}

final class PhotosAndCallsDecoderTests: XCTestCase {
    func testPhotosPage() throws {
        let m = try wire("photos.page", ["items": [
            ["id": 100, "name": "IMG_1.jpg", "taken": 1_700_000_000_000, "w": 4000, "h": 3000, "size": 3_000_000, "mime": "image/jpeg", "album": "camera"],
            ["id": 99, "name": "Screenshot_1.png", "taken": 1_699_999_000_000, "w": 1080, "h": 2400, "size": 400_000, "mime": "image/png", "album": "screenshots"],
            ["name": "no id"],
        ], "more": true])
        let page = try XCTUnwrap(PhotosDecode.page(m, request: PhotosRequest(album: .all, before: Date(timeIntervalSince1970: 1_700_000_500))))
        XCTAssertEqual(page.items.count, 2)
        XCTAssertTrue(page.more)
        XCTAssertEqual(page.album, .all)
        XCTAssertEqual(page.before, Date(timeIntervalSince1970: 1_700_000_500))
        XCTAssertEqual(page.items[0].id.text, "100")
        XCTAssertEqual(page.items[0].aspect, 4.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(page.items[1].album, "screenshots")
        XCTAssertEqual(page.items[1].mime, "image/png")
        XCTAssertFalse(page.items[0].isVideo)
        // Without a matching request and without an album in the reply the page can't be placed.
        XCTAssertNil(PhotosDecode.page(m, request: nil))
        // An album in the reply wins over the request.
        let echoed = try wire("photos.page", ["items": [Any](), "more": false, "album": "screenshots"])
        XCTAssertEqual(PhotosDecode.page(echoed, request: PhotosRequest(album: .all, before: nil))?.album, .screenshots)
    }

    func testCallsPage() throws {
        let m = try wire("calls.page", ["items": [
            ["number": "+15551230001", "name": "Maya", "kind": "missed", "date": 1_700_000_000_000, "duration": 0],
            ["number": "+15551230002", "name": "", "kind": "out", "date": 1_700_000_100_000, "duration": 125],
            ["number": "+15551230003", "kind": "in", "date": 1_700_000_200_000, "duration": 3700],
            ["number": "", "name": "", "kind": "rejected", "date": 1_700_000_300_000],
            ["number": "x", "kind": "voicemail", "date": 1_700_000_400_000],
            ["number": "y", "kind": "in"],
        ]])
        let c = CallRecord.page(m)
        XCTAssertEqual(c.map(\.kind), [.missed, .outgoing, .incoming, .rejected], "unknown kinds and entries without a date are dropped")
        XCTAssertEqual(c[0].title, "Maya")
        XCTAssertEqual(c[1].title, "+15551230002")
        XCTAssertEqual(c[3].title, "Unknown")
        XCTAssertEqual(c[1].duration, 125)
        XCTAssertTrue(c[0].isMissed); XCTAssertTrue(c[3].isMissed); XCTAssertFalse(c[1].isMissed)
        XCTAssertEqual(Set(c.map(\.id)).count, 4, "ids are unique")
    }

    func testRequestBookIsFirstInFirstOutAndExpires() {
        var b = RequestBook<Int>(lifetime: 10)
        let t0 = Date(timeIntervalSince1970: 1000)
        b.push(1, now: t0); b.push(2, now: t0.addingTimeInterval(3)); b.push(3, now: t0.addingTimeInterval(8))
        XCTAssertEqual(b.pop(now: t0.addingTimeInterval(9)), 1)
        XCTAssertEqual(b.pop(now: t0.addingTimeInterval(11)), 2, "2 is still fresh at +11 (pushed at +3)")
        XCTAssertEqual(b.pop(now: t0.addingTimeInterval(20)), nil, "3 expired at +18")
        XCTAssertNil(b.pop(now: t0.addingTimeInterval(21)))
        b.push(4, now: t0); b.removeAll()
        XCTAssertNil(b.pop(now: t0))
    }
}

final class ConversationHistoryTests: XCTestCase {
    private func n(_ msgs: [(String, String, Int64)], key: String = "k", pkg: String = "com.whatsapp", title: String = "Goa trip", group: Bool = true,
                   text: String? = nil, otp: OneTimeCode? = nil) -> PhoneNotification {
        PhoneNotification(key: key, pkg: pkg, app: "WhatsApp", title: title, text: text ?? msgs.last?.1 ?? "", when: Date(timeIntervalSince1970: Double(msgs.last?.2 ?? 0) / 1000),
                          canReply: true, category: .message,
                          conversation: Conversation(title: title, isGroup: group, messages: msgs.map {
                              ConversationMessage(sender: $0.0, text: $0.1, when: Date(timeIntervalSince1970: Double($0.2) / 1000))
                          }), otp: otp)
    }

    func testBuildsUpAndDeduplicates() {
        var h = ConversationHistory()
        XCTAssertTrue(h.record(n([("Maya", "one", 1000), ("Dev", "two", 2000)])))
        XCTAssertTrue(h.record(n([("Dev", "two", 2000), ("", "three", 3000), ("Dev", "four", 4000)])))
        XCTAssertFalse(h.record(n([("Dev", "two", 2000), ("", "three", 3000), ("Dev", "four", 4000)])), "same payload again changes nothing")
        let c = h.conversations[ConversationHistory.conversationID(pkg: "com.whatsapp", title: "Goa trip")]
        XCTAssertEqual(c?.messages.map(\.text), ["one", "two", "three", "four"])
        XCTAssertEqual(c?.messages.map(\.sender), ["Maya", "Dev", "", "Dev"])
        XCTAssertEqual(c?.isGroup, true)
        XCTAssertEqual(c?.lastKey, "k")
        // Same text, sender and time but a different sender is a different message; same sender and text at another time too.
        h.record(n([("Maya", "two", 2000), ("Dev", "two", 5000)]))
        XCTAssertEqual(h.conversations.values.first?.messages.count, 6)
        XCTAssertEqual(h.conversations.values.first?.messages.map(\.when), [1000, 2000, 2000, 3000, 4000, 5000], "kept in time order")
    }

    func testOlderMessagesArrivingLateSlotIntoPlace() {
        var h = ConversationHistory()
        h.record(n([("A", "late", 9000)]))
        h.record(n([("A", "early", 1000), ("A", "late", 9000)]))
        XCTAssertEqual(h.sorted().first?.messages.map(\.text), ["early", "late"])
    }

    func testCapKeepsTheNewest() {
        var h = ConversationHistory()
        for i in 0..<250 { h.record(n([("Dev", "m\(i)", Int64(1000 + i))])) }
        let c = h.sorted()[0]
        XCTAssertEqual(c.messages.count, ConversationHistory.cap)
        XCTAssertEqual(c.messages.first?.text, "m50")
        XCTAssertEqual(c.messages.last?.text, "m249")
    }

    func testConversationsAreKeyedByAppAndTitle() {
        var h = ConversationHistory()
        h.record(n([("Maya", "a", 1000)], pkg: "com.whatsapp", title: "Maya", group: false))
        h.record(n([("Maya", "b", 2000)], pkg: "org.telegram.messenger", title: "Maya", group: false))
        h.record(n([("Dev", "c", 3000)], pkg: "com.whatsapp", title: "Goa"))
        XCTAssertEqual(h.conversations.count, 3)
        XCTAssertEqual(h.sorted().map(\.title), ["Goa", "Maya", "Maya"], "newest first")
    }

    func testLocalReplyIsReplacedByThePhonesEcho() {
        var h = ConversationHistory()
        h.record(n([("Dev", "hello", 1_000_000)]))
        let id = ConversationHistory.conversationID(pkg: "com.whatsapp", title: "Goa trip")
        XCTAssertTrue(h.addLocalReply(id: id, text: "on my way", at: Date(timeIntervalSince1970: 1001)))
        XCTAssertEqual(h.conversations[id]?.messages.last?.local, true)
        // The phone later echoes the reply with its own timestamp, a few seconds off.
        h.record(n([("Dev", "hello", 1_000_000), ("", "on my way", 1_006_000)]))
        let msgs = h.conversations[id]?.messages ?? []
        XCTAssertEqual(msgs.map(\.text), ["hello", "on my way"], "no duplicate")
        XCTAssertNil(msgs.last?.local)
        XCTAssertEqual(msgs.last?.when, 1_006_000)
        // The same words sent much later are a new message.
        h.addLocalReply(id: id, text: "ok", at: Date(timeIntervalSince1970: 1100))
        h.record(n([("", "ok", 9_000_000)]))
        XCTAssertEqual(h.conversations[id]?.messages.map(\.text), ["hello", "on my way", "ok", "ok"])
        XCTAssertFalse(h.addLocalReply(id: "missing", text: "x"))
    }

    func testSparsePayloadsAndCodes() {
        var h = ConversationHistory()
        // Older phone build: a message notification without a conversation.
        let sparse = PhoneNotification(key: "s", pkg: "org.telegram.messenger", app: "Telegram", title: "Maya", text: "ping", when: Date(timeIntervalSince1970: 5), category: .message)
        XCTAssertTrue(h.record(sparse))
        let c = h.sorted()[0]
        XCTAssertEqual(c.title, "Maya"); XCTAssertEqual(c.messages.first?.sender, "Maya"); XCTAssertEqual(c.messages.first?.text, "ping")
        // Not a message: ignored. A code: not kept.
        XCTAssertFalse(h.record(PhoneNotification(key: "g", pkg: "com.google.android.gm", app: "Gmail", title: "Hi", text: "x")))
        XCTAssertFalse(h.record(n([("HDFCBK", "482196 is your OTP", 1000)], pkg: "com.google.android.apps.messaging", title: "HDFCBK", group: false, otp: OneTimeCode(code: "482196"))))
        XCTAssertEqual(h.conversations.count, 1)
    }

    func testKeyAndPersistence() throws {
        var h = ConversationHistory()
        h.record(n([("Dev", "hi", 1000)], key: "keyA"))
        let id = ConversationHistory.conversationID(pkg: "com.whatsapp", title: "Goa trip")
        h.clearKey("keyA")
        XCTAssertNil(h.conversations[id]?.lastKey)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mydroid-hist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.json")
        h.save(to: url)
        XCTAssertEqual(ConversationHistory.load(from: url), h)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600, "private to the user")
        XCTAssertEqual(ConversationHistory.load(from: dir.appendingPathComponent("nope.json")), ConversationHistory())
        h.remove(id)
        XCTAssertTrue(h.conversations.isEmpty)
    }
}

private final class Events: @unchecked Sendable {
    private let lock = NSLock(); private var list: [HubEvent] = []; private var cursor = 0
    func add(_ e: HubEvent) { lock.lock(); list.append(e); lock.unlock() }
    func next<T>(timeout: TimeInterval = 5, _ match: (HubEvent) -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            while cursor < list.count {
                let e = list[cursor]; cursor += 1
                if let r = match(e) { lock.unlock(); return r }
            }
            lock.unlock()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "test", code: 3, userInfo: [NSLocalizedDescriptionKey: "timed out waiting for hub event"])
    }
}

final class V13LoopbackTests: XCTestCase {
    private var dir: URL!
    private var hub: Hub!
    private var client: TestClient!
    private var events: Events!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mydroid-v13-\(UUID().uuidString)")
        let store = FileKeyValueStore(directory: dir.appendingPathComponent("secrets"))
        let ltk = MydroidCrypto.randomBytes(32)
        let identity = Identity(store: store)
        identity.savePairing(phoneId: "phone-1", ltk: ltk, phoneName: "Pixel 9")
        hub = Hub(HubConfiguration(macName: "Test Mac", identity: identity, config: store,
                                   ledgerURL: dir.appendingPathComponent("ledger.json"),
                                   photosDirectory: dir.appendingPathComponent("Pictures"),
                                   downloadsDirectory: dir.appendingPathComponent("Downloads"),
                                   preferredPort: 0, advertiseBonjour: false,
                                   libraryDirectory: dir.appendingPathComponent("Library")))
        events = Events()
        let ev = events!
        hub.onEvent = { ev.add($0) }
        let port = try XCTUnwrap(hub.startAndWait())
        client = TestClient(port: port)
        try await client.connect()
        try await client.handshake(phoneId: "phone-1", macId: hub.macId, ltk: ltk, pairing: false)
        _ = try await client.receive(type: "settings")
        try await client.send(Message("ping")); _ = try await client.receive(type: "pong")
    }

    override func tearDown() async throws {
        client.drop()
        hub.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    func testSmsRoundTrip() async throws {
        hub.requestSmsThreads(limit: 20, before: Date(timeIntervalSince1970: 1_700_000_000))
        let req = try await client.receive(type: "sms.threads.get")
        XCTAssertEqual(req.int("limit"), 20)
        XCTAssertEqual(req.int("before"), 1_700_000_000_000)
        try await client.send(Message("sms.threads", ["threads": [["threadId": 7, "addresses": ["+1555"], "name": "Maya", "snippet": "hi", "date": 1_700_000_000_000, "unread": 1]]]))
        let (threads, request) = try await events.next { e -> ([SmsThread], SmsThreadsRequest?)? in
            if case let .smsThreads(t, r) = e { return (t, r) } else { return nil } }
        XCTAssertEqual(threads.map(\.name), ["Maya"])
        XCTAssertEqual(request, SmsThreadsRequest(limit: 20, before: Date(timeIntervalSince1970: 1_700_000_000)), "the reply is paired with the request that asked for it")

        // The id goes back the way the phone wrote it.
        hub.requestSmsMessages(threadId: threads[0].id, limit: 30)
        let get = try await client.receive(type: "sms.messages.get")
        XCTAssertEqual(get.fields["threadId"] as? Int, 7)
        XCTAssertEqual(get.int("limit"), 30)
        XCTAssertNil(get.fields["before"])
        try await client.send(Message("sms.messages", ["threadId": 7, "messages": [["id": 1, "from": "+1555", "body": "hi", "date": 1_700_000_000_000, "out": false, "status": "received"]]]))
        let (tid, msgs) = try await events.next { e -> (WireID, [SmsMessage])? in if case let .smsMessages(t, m) = e { return (t, m) } else { return nil } }
        XCTAssertEqual(tid.text, "7"); XCTAssertEqual(msgs.count, 1)

        let cid = hub.sendSms(to: ["+1555", "+1666"], text: "hello there", threadId: tid)
        let send = try await client.receive(type: "sms.send")
        XCTAssertEqual(send.string("clientId"), cid)
        XCTAssertEqual(send.fields["to"] as? [String], ["+1555", "+1666"])
        XCTAssertEqual(send.string("text"), "hello there")
        XCTAssertEqual(send.fields["threadId"] as? Int, 7)
        let noThread = hub.sendSms(to: ["+1999"], text: "new")
        let send2 = try await client.receive(type: "sms.send")
        XCTAssertEqual(send2.string("clientId"), noThread)
        XCTAssertNil(send2.fields["threadId"])

        try await client.send(Message("sms.sent", ["clientId": cid, "ok": true, "threadId": 7]))
        let sent = try await events.next { e -> SmsSent? in if case let .smsSent(s) = e { return s } else { return nil } }
        XCTAssertEqual(sent.clientId, cid); XCTAssertTrue(sent.ok)
        try await client.send(Message("sms.changed", ["threadId": 7]))
        let changed = try await events.next { e -> WireID? in if case let .smsChanged(t) = e { return t } else { return nil } }
        XCTAssertEqual(changed.text, "7")
        try await client.send(Message("sms.error", ["error": "permission", "req": "sms.threads.get"]))
        let err = try await events.next { e -> [String]? in if case let .smsError(s, r) = e { return [s, r ?? "-"] } else { return nil } }
        XCTAssertEqual(err, ["permission", "sms.threads.get"])
        try await client.send(Message("sms.error", ["error": "permission"]))
        let bare = try await events.next { e -> [String]? in if case let .smsError(s, r) = e { return [s, r ?? "-"] } else { return nil } }
        XCTAssertEqual(bare, ["permission", "-"], "older phones don't say which request failed")

        hub.fix(.sms)
        let fix = try await client.receive(type: "fix.open")
        XCTAssertEqual(fix.string("what"), "sms")
        hub.markRead(key: "0|com.whatsapp|1")
        let read = try await client.receive(type: "notif.read")
        XCTAssertEqual(read.string("key"), "0|com.whatsapp|1")
    }

    func testOpenOnPhoneAndRichNotificationFields() async throws {
        hub.openOnPhone(key: "0|com.whatsapp|7")
        let open = try await client.receive(type: "notif.open")
        XCTAssertEqual(open.string("key"), "0|com.whatsapp|7")
        try await client.send(Message("notif.result", ["key": "0|com.whatsapp|7", "ok": true]))
        let ok = try await events.next { e -> Bool? in if case let .notificationResult(k, ok, _) = e, k == "0|com.whatsapp|7" { return ok } else { return nil } }
        XCTAssertTrue(ok)

        try await client.send(Message("notif.posted", ["key": "k9", "pkg": "com.whatsapp", "title": "Maya", "text": "hi",
                                                       "person": ["name": "Maya", "phone": "+91 98765 43210"],
                                                       "links": ["https://example.com/a", "javascript:alert(1)"]]))
        let n = try await events.next { e -> PhoneNotification? in if case let .notificationPosted(n, _) = e { return n } else { return nil } }
        XCTAssertEqual(n.person, NotificationPerson(name: "Maya", phone: "+919876543210"))
        XCTAssertEqual(n.links.map(\.absoluteString), ["https://example.com/a"])
    }

    func testPhotoLibrary() async throws {
        hub.requestPhotos(limit: 60, before: nil, album: .screenshots)
        hub.requestPhotos(limit: 60, before: Date(timeIntervalSince1970: 1_700_000_000), album: .all)
        let a = try await client.receive(type: "photos.list")
        XCTAssertEqual(a.string("album"), "screenshots"); XCTAssertEqual(a.int("limit"), 60); XCTAssertNil(a.fields["before"])
        let b = try await client.receive(type: "photos.list")
        XCTAssertEqual(b.string("album"), "all"); XCTAssertEqual(b.int("before"), 1_700_000_000_000)
        // Replies are matched in the order the requests went out.
        try await client.send(Message("photos.page", ["items": [["id": 5, "name": "Screenshot_1.png", "taken": 1_700_000_000_000, "w": 10, "h": 20, "size": 1, "mime": "image/png", "album": "screenshots"]], "more": false]))
        try await client.send(Message("photos.page", ["items": [["id": 4, "name": "IMG_1.jpg", "taken": 1_699_000_000_000, "w": 10, "h": 20, "size": 1, "mime": "image/jpeg", "album": "camera"]], "more": true]))
        let p1 = try await events.next { e -> PhotosPage? in if case let .photosPage(p) = e { return p } else { return nil } }
        let p2 = try await events.next { e -> PhotosPage? in if case let .photosPage(p) = e { return p } else { return nil } }
        XCTAssertEqual(p1.album, .screenshots); XCTAssertNil(p1.before); XCTAssertFalse(p1.more)
        XCTAssertEqual(p2.album, .all); XCTAssertEqual(p2.before, Date(timeIntervalSince1970: 1_700_000_000)); XCTAssertTrue(p2.more)

        // Thumbnails: batches of 30, one reply per id with the JPEG as payload.
        let ids = (1...65).map { WireID("\($0)", numeric: true) }
        hub.requestThumbs(ids: ids)
        var sizes: [Int] = []
        for _ in 0..<3 { sizes.append(((try await client.receive(type: "photos.thumbs.get")).fields["ids"] as? [Int])?.count ?? -1) }
        XCTAssertEqual(sizes, [30, 30, 5])
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 9, 9, 9])
        try await client.send(Message("photos.thumb", ["id": 12], payload: jpeg))
        let (tid, data) = try await events.next { e -> (WireID, Data)? in if case let .photoThumb(i, d) = e { return (i, d) } else { return nil } }
        XCTAssertEqual(tid.text, "12"); XCTAssertEqual(data, jpeg)

        // Calls.
        hub.requestCalls(limit: 40)
        let cl = try await client.receive(type: "calls.list")
        XCTAssertEqual(cl.int("limit"), 40)
        try await client.send(Message("calls.page", ["items": [["number": "+1555", "name": "Maya", "kind": "missed", "date": 1_700_000_000_000, "duration": 0]]]))
        let calls = try await events.next { e -> [CallRecord]? in if case let .callsPage(c, _) = e { return c } else { return nil } }
        XCTAssertEqual(calls.map(\.title), ["Maya"])
        try await client.send(Message("calls.page", ["items": [Any](), "error": "permission"]))
        let denied = try await events.next { e -> String? in if case let .callsPage(c, err) = e, c.isEmpty { return err } else { return nil } }
        XCTAssertEqual(denied, "permission")
        // The phone says "can't read photos" on the page itself, and "no thumbnail" with ok:false and no payload.
        hub.requestPhotos(limit: 10, before: nil, album: .camera)
        _ = try await client.receive(type: "photos.list")
        try await client.send(Message("photos.page", ["items": [Any](), "more": false, "error": "permission"]))
        let noAccess = try await events.next { e -> PhotosPage? in if case let .photosPage(p) = e, p.error != nil { return p } else { return nil } }
        XCTAssertEqual(noAccess.error, "permission"); XCTAssertEqual(noAccess.album, .camera); XCTAssertTrue(noAccess.items.isEmpty)
        try await client.send(Message("photos.thumb", ["id": 13, "ok": false]))
        let none = try await events.next { e -> (WireID, Data)? in if case let .photoThumb(i, d) = e, i.text == "13" { return (i, d) } else { return nil } }
        XCTAssertTrue(none.1.isEmpty, "an empty thumbnail means it failed")
        hub.dial(number: "+1 555 0100")
        let dial = try await client.receive(type: "call.dial")
        XCTAssertEqual(dial.string("number"), "+1 555 0100")
    }

    func testLibraryDownloadGoesToTheCacheNotTheLedger() async throws {
        let id = WireID("77", numeric: true)
        hub.downloadPhoto(id: id)
        let get = try await client.receive(type: "photos.get")
        XCTAssertEqual(get.fields["id"] as? Int, 77)

        let data = MydroidCrypto.randomBytes(300_000)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        func upload() async throws {
            try await client.send(Message("xfer.offer", ["xid": "lib:77", "kind": "photo", "name": "IMG_0077.jpg", "size": data.count, "mime": "image/jpeg"]))
            let accept = try await client.receive(type: "xfer.accept")
            XCTAssertEqual(accept.int("offset"), 0, "a library download always starts from the top")
            try await client.send(Message("xfer.chunk", ["xid": "lib:77", "offset": 0], payload: data.prefix(262_144)))
            try await client.send(Message("xfer.chunk", ["xid": "lib:77", "offset": 262_144], payload: data.dropFirst(262_144)))
            try await client.send(Message("xfer.end", ["xid": "lib:77", "sha256": sha]))
            let done = try await client.receive(type: "xfer.done")
            XCTAssertEqual(done.bool("ok"), true)
        }
        try await upload()
        let url = try await events.next { e -> URL? in if case let .libraryReady(i, u) = e, i == "77" { return u } else { return nil } }
        XCTAssertEqual(url, hub.libraryFile(id: id, name: "IMG_0077.jpg"))
        XCTAssertTrue(url.path.hasPrefix(dir.appendingPathComponent("Library").path), "stored in the cache directory")
        XCTAssertEqual(try Data(contentsOf: url), data)
        let pictures = (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("Pictures").path)) ?? []
        XCTAssertEqual(pictures, [], "nothing lands in the auto-sync folder")
        XCTAssertNil(hub.snapshot.latestPhoto, "and it isn't the latest synced photo")
        XCTAssertTrue(hub.recentTransfers().isEmpty, "never recorded in the dedupe ledger")
        XCTAssertTrue(hub.snapshot.transfers.isEmpty)

        // Downloading it again is not skipped, even though it finished before; the file is replaced.
        try FileManager.default.removeItem(at: url)
        try await upload()
        _ = try await events.next { e -> URL? in if case let .libraryReady(i, u) = e, i == "77" { return u } else { return nil } }
        XCTAssertEqual(try Data(contentsOf: url), data)

        // A normal synced photo still dedupes and goes to Pictures.
        try await client.send(Message("xfer.offer", ["xid": "photo:1:100", "kind": "photo", "name": "IMG_1.jpg", "size": 3, "mime": "image/jpeg"]))
        _ = try await client.receive(type: "xfer.accept")
        try await client.send(Message("xfer.chunk", ["xid": "photo:1:100", "offset": 0], payload: Data([1, 2, 3])))
        try await client.send(Message("xfer.end", ["xid": "photo:1:100", "sha256": SHA256.hash(data: Data([1, 2, 3])).map { String(format: "%02x", $0) }.joined()]))
        _ = try await client.receive(type: "xfer.done")
        _ = try await events.next { e -> SavedFile? in if case let .received(f) = e { return f } else { return nil } }
        XCTAssertEqual(hub.recentTransfers().map(\.xid), ["photo:1:100"])
        XCTAssertEqual(hub.syncedPhoto(name: "IMG_1.jpg", size: 3)?.xid, "photo:1:100")
        XCTAssertNil(hub.syncedPhoto(name: "IMG_1.jpg", size: 4))
        try await client.send(Message("xfer.offer", ["xid": "photo:1:100", "kind": "photo", "name": "IMG_1.jpg", "size": 3, "mime": "image/jpeg"]))
        _ = try await client.receive(type: "xfer.skip")
    }

    func testRefusedLibraryDownloadFailsAtOnce() async throws {
        hub.downloadPhoto(id: WireID("5", numeric: true))
        _ = try await client.receive(type: "photos.get")
        try await client.send(Message("xfer.cancel", ["xid": "lib:5"]))
        let r = try await events.next { e -> [String]? in if case let .libraryFailed(i, err) = e { return [i, err] } else { return nil } }
        XCTAssertEqual(r.first, "5")
    }

    func testFailedLibraryDownloadReportsAndLeavesNoLedgerEntry() async throws {
        try await client.send(Message("xfer.offer", ["xid": "lib:9", "kind": "photo", "name": "bad.jpg", "size": 3, "mime": "image/jpeg"]))
        _ = try await client.receive(type: "xfer.accept")
        try await client.send(Message("xfer.chunk", ["xid": "lib:9", "offset": 0], payload: Data([1, 2, 3])))
        try await client.send(Message("xfer.end", ["xid": "lib:9", "sha256": String(repeating: "0", count: 64)]))
        let done = try await client.receive(type: "xfer.done")
        XCTAssertEqual(done.bool("ok"), false)
        let failed = try await events.next { e -> String? in if case let .libraryFailed(i, _) = e { return i } else { return nil } }
        XCTAssertEqual(failed, "9")
        XCTAssertTrue(hub.recentTransfers().isEmpty)
    }
}

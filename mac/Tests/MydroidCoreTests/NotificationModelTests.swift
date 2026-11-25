import XCTest
@testable import MydroidCore

final class NotificationModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    private var ms: Int64 { Int64(t0.timeIntervalSince1970 * 1000) }

    func testDecodesAllRichFields() throws {
        let png = Data([1, 2, 3, 4])
        let m = Message("notif.posted", [
            "key": "k", "pkg": "com.whatsapp", "app": "WhatsApp", "title": "Trip", "text": "Dev: see you",
            "when": ms, "canReply": true, "category": "message",
            "conversation": [
                "title": "Trip", "isGroup": true, "avatar": png.base64EncodedString(),
                "messages": [
                    ["sender": "Maya", "text": "Hi", "when": ms - 2000],
                    ["sender": "", "text": "Hello", "when": ms - 1000],
                    ["sender": "Dev", "text": "see you", "when": ms],
                ],
            ],
            "otp": ["code": "482196", "source": "HDFC Bank"],
        ])
        let n = try XCTUnwrap(PhoneNotification(fields: try Message.decode(try m.encode()).fields))
        XCTAssertEqual(n.category, .message)
        XCTAssertTrue(n.isMessage)
        let c = try XCTUnwrap(n.conversation)
        XCTAssertEqual(c.title, "Trip")
        XCTAssertTrue(c.isGroup)
        XCTAssertEqual(c.avatar, png)
        XCTAssertEqual(c.messages.map(\.sender), ["Maya", "", "Dev"])
        XCTAssertTrue(c.messages[1].isMine)
        XCTAssertEqual(c.messages[2].when, t0)
        XCTAssertEqual(n.otp, OneTimeCode(code: "482196", source: "HDFC Bank"))
        XCTAssertEqual(n.otp?.grouped, "482 196")
    }

    func testKeepsOnlyLastFiveMessages() {
        let msgs = (0..<8).map { ["sender": "A", "text": "m\($0)", "when": ms + Int64($0)] as [String: Any] }
        let n = PhoneNotification(fields: ["key": "k", "category": "message", "conversation": ["title": "A", "messages": msgs]])!
        XCTAssertEqual(n.conversation?.messages.map(\.text), ["m3", "m4", "m5", "m6", "m7"])
    }

    func testOlderPayloadWithoutRichFields() throws {
        let n = try XCTUnwrap(PhoneNotification(fields: ["key": "k", "pkg": "com.whatsapp", "app": "com.whatsapp",
                                                         "title": "Maya", "text": "hey", "when": ms]))
        XCTAssertEqual(n.category, .other)
        XCTAssertNil(n.conversation)
        XCTAssertNil(n.otp)
        XCTAssertFalse(n.hasActiveCode(at: t0))
        XCTAssertEqual(n.displayApp, "WhatsApp")
        XCTAssertNil(n.effectiveConversation)
    }

    func testUnknownCategoryAndBadFieldsAreTolerated() {
        let n = PhoneNotification(fields: ["key": "k", "category": "weird", "otp": ["code": ""], "conversation": "nope"])!
        XCTAssertEqual(n.category, .other)
        XCTAssertNil(n.otp)
        XCTAssertNil(n.conversation)
    }

    func testMessageWithoutConversationGetsOne() {
        let n = PhoneNotification(key: "k", app: "Messages", title: "Mum", text: "call me", when: t0, category: .message)
        let c = n.effectiveConversation
        XCTAssertEqual(c?.title, "Mum")
        XCTAssertEqual(c?.messages.map(\.text), ["call me"])
        XCTAssertFalse(c?.isGroup ?? true)
    }

    func testOTPExpiry() {
        let n = PhoneNotification(key: "k", when: t0, otp: OneTimeCode(code: "123456"))
        XCTAssertEqual(n.otpExpiry, t0.addingTimeInterval(600))
        XCTAssertTrue(n.hasActiveCode(at: t0.addingTimeInterval(599)))
        XCTAssertFalse(n.hasActiveCode(at: t0.addingTimeInterval(600)))
        var list = NotificationList()
        list.post(n)
        list.post(PhoneNotification(key: "plain", when: t0))
        XCTAssertEqual(list.activeCodes(at: t0.addingTimeInterval(5)).map(\.key), ["k"])
        XCTAssertTrue(list.activeCodes(at: t0.addingTimeInterval(601)).isEmpty)
        list.remove("k")
        XCTAssertTrue(list.activeCodes(at: t0).isEmpty)
    }

    func testCodeGrouping() {
        XCTAssertEqual(OneTimeCode(code: "4821").grouped, "4821")
        XCTAssertEqual(OneTimeCode(code: "12345678").grouped, "1234 5678")
        XCTAssertEqual(OneTimeCode(code: "G-12AB").grouped, "G-12AB")
        XCTAssertEqual(OneTimeCode(code: "AB12CD").grouped, "AB12CD")
    }

    func testListSplitsMessagesAndOthers() {
        var list = NotificationList()
        list.post(PhoneNotification(key: "a", when: t0))
        list.post(PhoneNotification(key: "m", when: t0.addingTimeInterval(1), category: .message))
        XCTAssertEqual(list.messages.map(\.key), ["m"])
        XCTAssertEqual(list.others.map(\.key), ["a"])
    }

    func testNewerMessageInExistingConversationCountsAsNew() {
        var list = NotificationList()
        XCTAssertTrue(list.post(PhoneNotification(key: "m", when: t0)))
        XCTAssertFalse(list.post(PhoneNotification(key: "m", when: t0)))
        XCTAssertTrue(list.post(PhoneNotification(key: "m", when: t0.addingTimeInterval(3))))
    }

    func testAppNames() {
        XCTAssertEqual(AppNames.present("WhatsApp"), "WhatsApp")
        XCTAssertEqual(AppNames.present("Mr. Smith"), "Mr. Smith")
        XCTAssertEqual(AppNames.present("com.google.android.gm"), "Gmail")
        XCTAssertEqual(AppNames.present("com.google.android.apps.messaging"), "Messages")
        XCTAssertEqual(AppNames.present("org.telegram.messenger"), "Telegram")
        XCTAssertEqual(AppNames.present("com.acme.fooBar"), "FooBar")
        XCTAssertEqual(AppNames.present("com.acme.shop.android"), "Shop")
        XCTAssertEqual(AppNames.present(""), "")
    }

    func testHeartbeatTimeouts() {
        XCTAssertEqual(Server.idleTimeout, 240)
        let now = Date()
        XCTAssertFalse(Server.isIdle(ready: true, since: now.addingTimeInterval(-239), now: now))
        XCTAssertTrue(Server.isIdle(ready: true, since: now.addingTimeInterval(-241), now: now))
        XCTAssertFalse(Server.isIdle(ready: false, since: now.addingTimeInterval(-14), now: now))
        XCTAssertTrue(Server.isIdle(ready: false, since: now.addingTimeInterval(-16), now: now))
    }

    func testMacProbesOnlyAfterMissingThePhoneHeartbeat() {
        let lastFrame = Date()
        let probe = lastFrame.addingTimeInterval(100)
        XCTAssertFalse(Server.shouldProbe(since: lastFrame, now: lastFrame.addingTimeInterval(99)))
        XCTAssertTrue(Server.shouldProbe(since: lastFrame, now: probe))
        XCTAssertFalse(Server.isIdle(ready: true, since: lastFrame, now: probe.addingTimeInterval(15)))
    }
}

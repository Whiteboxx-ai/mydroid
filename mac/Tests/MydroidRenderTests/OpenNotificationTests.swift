import XCTest
@testable import Mydroid
@testable import MydroidCore

private struct FakeApps: AppLocator {
    var ids: Set<String> = []
    func isInstalled(bundleID: String) -> Bool { ids.contains(bundleID) }
}

/// Clicking, the right-click menu and "When clicked", driven with fixtures: nothing is opened on this Mac.
@MainActor
final class OpenNotificationTests: XCTestCase {
    private var opener: RecordingOpener!

    private func model(connected: Bool = true, apps: Set<String> = [], _ list: [PhoneNotification] = []) -> AppModel {
        var st = HubState()
        st.link = connected ? .connected : .searching
        st.phone = PhoneInfo(name: "Pixel 9")
        for n in list { st.notifications.post(n) }
        let m = AppModel(fixture: st)
        opener = RecordingOpener()
        m.opener = opener
        m.ui.router = OpenRouter(locator: FakeApps(ids: apps))
        return m
    }

    private func gmail() -> PhoneNotification {
        PhoneNotification(key: "g1", pkg: "com.google.android.gm", app: "Gmail", title: "Acme Billing", text: "Your invoice is ready\nPay by Friday")
    }

    private func chat(phone: String? = "+919876543210") -> PhoneNotification {
        PhoneNotification(key: "w1", pkg: "com.whatsapp", app: "WhatsApp", title: "Maya", text: "hi", canReply: true, category: .message,
                          conversation: Conversation(title: "Maya", messages: [ConversationMessage(sender: "Maya", text: "hi", when: Date())]),
                          person: phone.map { NotificationPerson(name: "Maya", phone: $0) })
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(80)) }

    func testWhatsAppWithoutContactNumberLaunchesWithoutAURL() async {
        let note = chat(phone: nil)
        let m = model(apps: ["net.whatsapp.WhatsApp"], [note])
        m.open(note)
        await settle()
        XCTAssertEqual(opener.opened.count, 1)
        XCTAssertEqual(opener.opened.first?.bundleID, "net.whatsapp.WhatsApp")
        XCTAssertNil(opener.opened.first?.url)
    }

    func testClickOpensTheDefaultForTheApp() async {
        let g = gmail()
        let m = model([g])
        m.open(g)
        await settle()
        XCTAssertEqual(opener.opened.map { $0.url?.absoluteString }, ["https://mail.google.com/mail/u/0/#search/subject%3A%22Your%20invoice%20is%20ready%22"])
        XCTAssertNil(opener.opened.first?.bundleID)
    }

    func testMacAppIsUsedWhenInstalledAndFallsBackToTheWebWhenItWontLaunch() async {
        let w = chat()
        let m = model(apps: ["net.whatsapp.WhatsApp"], [w])
        m.open(w)
        await settle()
        XCTAssertEqual(opener.opened.count, 1)
        XCTAssertEqual(opener.opened[0].bundleID, "net.whatsapp.WhatsApp")
        XCTAssertEqual(opener.opened[0].url?.absoluteString, "whatsapp://send?phone=919876543210")

        opener.opened = []; opener.failing = ["net.whatsapp.WhatsApp"]
        m.open(w)
        await settle()
        XCTAssertEqual(opener.opened.map { $0.url?.absoluteString }, ["whatsapp://send?phone=919876543210", "https://web.whatsapp.com/send?phone=919876543210"])
    }

    func testChoicesPerApp() async {
        let g = gmail()
        let m = model([g])
        m.setClickBehavior(.nothing, for: g.pkg)
        m.open(g)
        await settle()
        XCTAssertTrue(opener.opened.isEmpty, "Do nothing")
        XCTAssertNil(m.toast)

        m.setClickBehavior(.phone, for: g.pkg)
        m.open(g)
        await settle()
        XCTAssertTrue(opener.opened.isEmpty, "Open on phone goes to the phone, not the Mac")
        XCTAssertEqual(m.toast, "Opening on your phone")

        m.setClickBehavior(.web, for: g.pkg)
        m.open(g)
        await settle()
        XCTAssertEqual(opener.opened.count, 1)

        m.setClickBehavior(.default, for: g.pkg)
        XCTAssertEqual(m.prefs.clickBehavior, [:], "Default is stored as no entry")
    }

    func testOpeningOnThePhoneNeedsAConnection() async {
        let g = gmail()
        let m = model(connected: false, [g])
        m.openOnPhone(g)
        XCTAssertEqual(m.toast, "Pixel 9 isn't connected")
    }

    func testUnknownAppsGoToThePhone() async {
        let n = PhoneNotification(key: "s1", pkg: "com.slack", app: "Slack", title: "#design", text: "v3 is up")
        let m = model([n])
        m.open(n)
        await settle()
        XCTAssertTrue(opener.opened.isEmpty)
        XCTAssertEqual(m.toast, "Opening on your phone")
    }

    func testOpeningAConversationOnTheMacMarksItRead() async {
        let w = chat()
        let m = model([w])
        m.open(w)
        await settle()
        XCTAssertTrue(m.messages.unreadCleared.contains("w1"))
        // A notification that isn't a conversation is left alone.
        let g = gmail()
        let m2 = model([g])
        m2.open(g)
        await settle()
        XCTAssertTrue(m2.messages.unreadCleared.isEmpty)
    }

    func testAFailedOpenDoesNotMarkRead() async {
        let w = chat()
        let m = model([w])
        opener.failWeb = true
        m.open(w)
        await settle()
        XCTAssertFalse(m.messages.unreadCleared.contains("w1"))
        XCTAssertEqual(m.toast, "Couldn't open the page")
    }

    func testPhoneOpenResultMarksTheConversationReadAndFailureSaysSo() async {
        let w = chat()
        let m = model([w])
        m.setClickBehavior(.phone, for: w.pkg)
        m.open(w)
        XCTAssertFalse(m.messages.unreadCleared.contains("w1"), "not until the phone says it worked")
        m.handle(.notificationResult(key: "w1", ok: true, error: nil))
        XCTAssertTrue(m.messages.unreadCleared.contains("w1"))
        XCTAssertNil(m.replyStatus["w1"], "an open is not a reply")

        let m2 = model([chat()])
        m2.setClickBehavior(.phone, for: "com.whatsapp")
        m2.open(chat())
        m2.handle(.notificationResult(key: "w1", ok: false, error: "x"))
        XCTAssertEqual(m2.toast, "Couldn't open it on your phone")
        XCTAssertNil(m2.replyStatus["w1"])
    }

    func testRightClickMenu() async {
        let m = model()
        // Gmail: phone, web, search | copy, mute.
        let g = m.ui.menu(for: gmail()).map { $0.map(\.title) }
        XCTAssertEqual(g, [["Open on phone", "Open on web", "Search the web"], ["Copy text", "Mute Gmail"]])
        // An app with no web page: no "Open on web".
        let slack = PhoneNotification(key: "s", pkg: "com.slack", app: "Slack", title: "x", text: "y")
        XCTAssertEqual(m.ui.menu(for: slack).map { $0.map(\.title) }, [["Open on phone", "Search the web"], ["Copy text", "Mute Slack"]])
        // A verification code is never searched for.
        var otp = PhoneNotification(key: "o", pkg: "com.google.android.apps.messaging", app: "Messages", title: "HDFC", text: "482196 is your OTP")
        otp.otp = OneTimeCode(code: "482196")
        XCTAssertFalse(m.ui.menu(for: otp).flatMap { $0 }.contains { $0.kind == .search })
    }

    func testMenuActionsReachTheModel() async {
        let g = gmail()
        let m = model([g])
        m.ui.run(.openOnWeb, g)
        m.ui.run(.search, g)
        await settle()
        XCTAssertEqual(opener.opened.count, 2)
        XCTAssertEqual(opener.opened[1].url?.absoluteString, "https://www.google.com/search?q=Acme%20Billing%20Your%20invoice%20is%20ready%20Pay%20by%20Friday")
        m.ui.run(.mute, g)
        XCTAssertTrue(m.isMuted(g.pkg) || m.state.settings.mutedApps.contains(g.pkg))
    }

    func testSystemNotificationClick() async {
        let g = gmail()
        let m = model([g])
        m.openNotification(key: "g1")
        m.openNotification(key: "gone")
        await settle()
        XCTAssertEqual(opener.opened.count, 1)
    }

    func testPrefsPersistAndTolerateOldOrUnknownValues() throws {
        var p = MacPrefs()
        p.setClickBehavior(.nothing, for: "com.slack")
        p.setClickBehavior(.web, for: "com.twitter.android")
        let back = try JSONDecoder().decode(MacPrefs.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.clickBehavior(for: "com.slack"), .nothing)
        XCTAssertEqual(back.clickBehavior(for: "com.twitter.android"), .web)
        XCTAssertEqual(back.clickBehavior(for: "other"), .default)
        let old = try JSONDecoder().decode(MacPrefs.self, from: Data(#"{"followFocus":true}"#.utf8))
        XCTAssertTrue(old.followFocus); XCTAssertEqual(old.clickBehavior, [:])
        let odd = try JSONDecoder().decode(MacPrefs.self, from: Data(#"{"clickBehavior":{"a":"phone","b":"teleport"}}"#.utf8))
        XCTAssertEqual(odd.clickBehavior, ["a": .phone])
    }
}

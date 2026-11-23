import XCTest
@testable import MydroidCore

private struct Installed: AppLocator {
    var ids: Set<String> = []
    func isInstalled(bundleID: String) -> Bool { ids.contains(bundleID) }
}

private func note(_ pkg: String, title: String = "", text: String = "", message: Bool = false, phone: String? = nil,
                  group: Bool = false, links: [String] = [], media: NotificationMedia? = nil, key: String = "k1") -> PhoneNotification {
    var conv: Conversation?
    if message { conv = Conversation(title: title, isGroup: group, messages: [ConversationMessage(sender: title, text: text, when: Date())]) }
    return PhoneNotification(key: key, pkg: pkg, app: pkg, title: title, text: text,
                             category: message ? .message : .other, conversation: conv,
                             person: phone.map { NotificationPerson(name: title, phone: $0) },
                             links: links.compactMap(URL.init(string:)), media: media)
}

private func web(_ s: String) -> OpenAction { .web(URL(string: s)!) }

final class NotificationFieldsTests: XCTestCase {
    func testParsesPersonLinksAndMedia() {
        let n = PhoneNotification(fields: [
            "key": "k", "pkg": "com.spotify.music",
            "person": ["name": "Maya Tan", "phone": "+1 (555) 123-0001"],
            "links": ["https://a.example/x", "http://b.example", "https://a.example/x", "ftp://c.example", "mailto:x@y.z", "not a url", "https://d.example", "https://e.example"],
            "media": ["title": "Midnight City", "artist": "M83", "album": "Hurry Up", "mediaId": "spotify:track:6dGnYIeXmHdcikdzNNDMm2"],
        ])!
        XCTAssertEqual(n.person, NotificationPerson(name: "Maya Tan", phone: "+15551230001"))
        XCTAssertEqual(n.links.map(\.absoluteString), ["https://a.example/x", "http://b.example", "https://d.example"], "http(s) only, deduplicated, at most 3")
        XCTAssertEqual(n.media, NotificationMedia(title: "Midnight City", artist: "M83", album: "Hurry Up", mediaId: "spotify:track:6dGnYIeXmHdcikdzNNDMm2"))
    }

    func testOlderPayloadsStillParse() {
        let n = PhoneNotification(fields: ["key": "k", "pkg": "com.whatsapp", "title": "Maya", "text": "hi"])!
        XCTAssertNil(n.person); XCTAssertEqual(n.links, []); XCTAssertNil(n.media)
    }

    func testBadFieldsAreTolerated() {
        let n = PhoneNotification(fields: ["key": "k", "person": "Maya", "links": "https://x.example", "media": ["artist": "no title"]])!
        XCTAssertNil(n.person); XCTAssertEqual(n.links, []); XCTAssertNil(n.media)
        let p = PhoneNotification(fields: ["key": "k", "person": ["name": "Maya", "phone": "call me"], "links": [1, NSNull()],
                                           "media": ["title": "T", "mediaId": ""]])!
        XCTAssertEqual(p.person, NotificationPerson(name: "Maya", phone: nil), "a phone that is not a number is dropped")
        XCTAssertEqual(p.links, [])
        XCTAssertNil(p.media?.mediaId); XCTAssertEqual(p.media?.artist, "")
    }

    func testPhoneNormalisation() {
        XCTAssertEqual(NotificationPerson.normalizedPhone("+919876543210"), "+919876543210")
        XCTAssertEqual(NotificationPerson.normalizedPhone("98765-43210"), "+9876543210")
        XCTAssertNil(NotificationPerson.normalizedPhone("12345"))
        XCTAssertNil(NotificationPerson.normalizedPhone("+1234567890123456"))
        XCTAssertNil(NotificationPerson.normalizedPhone("tel:+15551230001x"))
        XCTAssertNil(NotificationPerson.normalizedPhone(nil))
    }
}

final class OpenRouterTests: XCTestCase {
    private let none = OpenRouter()
    private func router(_ ids: String...) -> OpenRouter { OpenRouter(locator: Installed(ids: Set(ids))) }

    // MARK: Fallbacks and links

    func testUnknownAppsOpenOnPhone() {
        let n = note("com.slack", title: "#design", text: "hi")
        XCTAssertEqual(none.action(for: n), .phone(key: "k1"))
        XCTAssertNil(none.plan(for: n).web)
    }

    func testAnyNotificationWithLinksOpensTheFirstLink() {
        let n = note("com.slack", title: "t", text: "see https://example.com/a", links: ["https://example.com/a", "https://example.com/b"])
        XCTAssertEqual(none.action(for: n), web("https://example.com/a"))
        XCTAssertEqual(none.plan(for: n).web, URL(string: "https://example.com/a"))
        // ...and beats the app's own rule.
        let x = note("com.twitter.android", title: "t", links: ["https://example.com/p"])
        XCTAssertEqual(none.action(for: x), web("https://example.com/p"))
    }

    func testOnlyWebLinksAreUsed() {
        var n = note("com.slack")
        n.links = [URL(string: "file:///etc/passwd")!, URL(string: "javascript:alert(1)")!, URL(string: "mailto:a@b.c")!]
        XCTAssertEqual(none.action(for: n), .phone(key: "k1"))
    }

    func testPackagesMatchCaseInsensitively() {
        XCTAssertNotNil(none.rule(forPackage: "COM.TWITTER.ANDROID"))
    }

    // MARK: Gmail

    func testGmailSearchesTheSubject() {
        let n = note("com.google.android.gm", title: "Acme Billing", text: "Your invoice is ready\nPay by Friday")
        XCTAssertEqual(none.action(for: n), web("https://mail.google.com/mail/u/0/#search/subject%3A%22Your%20invoice%20is%20ready%22"))
    }

    func testGmailSubjectIsEncoded() {
        let n = note("com.google.android.gm", title: "A", text: "Q&A: 50% off + more? #deals \"quoted\" café")
        XCTAssertEqual(none.action(for: n),
                       web("https://mail.google.com/mail/u/0/#search/subject%3A%22Q%26A%3A%2050%25%20off%20%2B%20more%3F%20%23deals%20quoted%20caf%C3%A9%22"))
    }

    func testGmailFallsBackToTitleThenInbox() {
        XCTAssertEqual(none.action(for: note("com.google.android.gm", title: "Weekly digest", text: "")),
                       web("https://mail.google.com/mail/u/0/#search/subject%3A%22Weekly%20digest%22"))
        XCTAssertEqual(none.action(for: note("com.google.android.gm", title: "Weekly digest", text: "\n  \nSecond")),
                       web("https://mail.google.com/mail/u/0/#search/subject%3A%22Second%22"), "blank leading lines are skipped")
        XCTAssertEqual(none.action(for: note("com.google.android.gm")), web("https://mail.google.com/mail/u/0/#inbox"))
        XCTAssertTrue(OpenRouter.gmailSearch(title: "", text: "  ") == nil)
    }

    func testGmailLongSubjectIsCut() {
        let long = String(repeating: "word ", count: 80)
        let q = OpenRouter.gmailSearch(title: "", text: long)!
        XCTAssertLessThanOrEqual(q.count, 150 + 11)
    }

    // MARK: WhatsApp and Telegram

    func testWhatsAppWithPhone() {
        let n = note("com.whatsapp", title: "Maya", text: "hi", message: true, phone: "+919876543210")
        XCTAssertEqual(none.action(for: n), web("https://web.whatsapp.com/send?phone=919876543210"))
        XCTAssertEqual(router("net.whatsapp.WhatsApp").action(for: n),
                       .macApp(bundleID: "net.whatsapp.WhatsApp", url: URL(string: "whatsapp://send?phone=919876543210")!,
                               fallback: URL(string: "https://web.whatsapp.com/send?phone=919876543210")))
        XCTAssertEqual(none.plan(for: n).web, URL(string: "https://web.whatsapp.com/send?phone=919876543210"),
                       "Open on web is the web chat even when the Mac app exists")
        XCTAssertEqual(router("net.whatsapp.WhatsApp").plan(for: n).web, URL(string: "https://web.whatsapp.com/send?phone=919876543210"))
    }

    func testWhatsAppBusinessUsesTheSameRule() {
        let n = note("com.whatsapp.w4b", title: "Shop", text: "hi", message: true, phone: "+14155550123")
        XCTAssertEqual(none.action(for: n), web("https://web.whatsapp.com/send?phone=14155550123"))
    }

    func testWhatsAppWithoutPhoneOrInAGroupOpensHome() {
        let dm = note("com.whatsapp", title: "Maya", text: "hi", message: true)
        XCTAssertEqual(none.action(for: dm), web("https://web.whatsapp.com/"))
        XCTAssertEqual(router("net.whatsapp.WhatsApp").action(for: dm),
                       .macApp(bundleID: "net.whatsapp.WhatsApp", url: URL(string: "whatsapp://")!, fallback: URL(string: "https://web.whatsapp.com/")))
        // A group never opens a one-to-one chat with whoever spoke last.
        let group = note("com.whatsapp", title: "Goa trip", text: "Dev: hi", message: true, phone: "+919876543210", group: true)
        XCTAssertEqual(none.action(for: group), web("https://web.whatsapp.com/"))
    }

    func testTelegram() {
        let n = note("org.telegram.messenger", title: "Maya", text: "hi", message: true, phone: "+15551230001")
        XCTAssertEqual(none.action(for: n), web("https://web.telegram.org/"))
        XCTAssertEqual(router("ru.keepcoder.Telegram").action(for: n),
                       .macApp(bundleID: "ru.keepcoder.Telegram", url: URL(string: "tg://resolve?phone=15551230001")!, fallback: URL(string: "https://web.telegram.org/")))
        XCTAssertEqual(router("org.telegram.desktop").action(for: n),
                       .macApp(bundleID: "org.telegram.desktop", url: URL(string: "tg://resolve?phone=15551230001")!, fallback: URL(string: "https://web.telegram.org/")))
        XCTAssertEqual(router("org.telegram.desktop", "ru.keepcoder.Telegram").action(for: n),
                       .macApp(bundleID: "ru.keepcoder.Telegram", url: URL(string: "tg://resolve?phone=15551230001")!, fallback: URL(string: "https://web.telegram.org/")),
                       "the native app is preferred")
        let noPhone = note("org.telegram.messenger", title: "Group", text: "hi", message: true)
        XCTAssertEqual(router("ru.keepcoder.Telegram").action(for: noPhone),
                       .macApp(bundleID: "ru.keepcoder.Telegram", url: URL(string: "tg://")!, fallback: URL(string: "https://web.telegram.org/")))
    }

    // MARK: X, Instagram, LinkedIn

    func testXInstagramLinkedInSplitMessagesFromTheRest() {
        for (pkg, msg, other) in [
            ("com.twitter.android", "https://x.com/messages", "https://x.com/notifications"),
            ("com.instagram.android", "https://www.instagram.com/direct/inbox/", "https://www.instagram.com/"),
            ("com.linkedin.android", "https://www.linkedin.com/messaging/", "https://www.linkedin.com/notifications/"),
        ] {
            XCTAssertEqual(none.action(for: note(pkg, title: "Maya", text: "hi", message: true)), web(msg), pkg)
            XCTAssertEqual(none.action(for: note(pkg, title: "Maya", text: "liked your post")), web(other), pkg)
        }
        // "message" also means the notification has a conversation, whatever its category.
        var n = note("com.twitter.android", title: "Maya", text: "hi")
        n.conversation = Conversation(title: "Maya", messages: [ConversationMessage(sender: "Maya", text: "hi", when: Date())])
        XCTAssertEqual(none.action(for: n), web("https://x.com/messages"))
        // category == message without a conversation counts too.
        var m = note("com.twitter.android", title: "Maya", text: "hi")
        m.category = .message
        XCTAssertEqual(none.action(for: m), web("https://x.com/messages"))
    }

    // MARK: YouTube

    func testYouTubeChannelInTitleVideoInText() {
        XCTAssertEqual(none.action(for: note("com.google.android.youtube", title: "MKBHD", text: "iPhone 17 Pro review: the truth")),
                       web("https://www.youtube.com/results?search_query=MKBHD%20iPhone%2017%20Pro%20review%3A%20the%20truth"))
    }

    func testYouTubeVideoInTitleChannelInText() {
        XCTAssertEqual(OpenRouter.youtubeQuery(title: "iPhone 17 Pro review", text: "MKBHD"), "iPhone 17 Pro review MKBHD")
    }

    func testYouTubeUploadedPhrasing() {
        XCTAssertEqual(OpenRouter.youtubeQuery(title: "New video", text: "MKBHD uploaded: iPhone 17 Pro review"), "MKBHD iPhone 17 Pro review")
        XCTAssertEqual(OpenRouter.youtubeQuery(title: "Veritasium", text: "is live: Ask me anything"), "Veritasium Ask me anything", "no channel in the text")
        XCTAssertEqual(OpenRouter.youtubeQuery(title: "Kurzgesagt", text: "New: The Egg"), "Kurzgesagt The Egg")
        XCTAssertEqual(OpenRouter.youtubeQuery(title: "Kurzgesagt is live", text: "Live: Q&A"), "Kurzgesagt Q&A")
        XCTAssertEqual(OpenRouter.youtubeQuery(title: "New video from Kurzgesagt", text: "The Egg"), "Kurzgesagt The Egg")
    }

    func testYouTubeFallsBackToWholeTextAndHome() {
        XCTAssertEqual(OpenRouter.youtubeQuery(title: "", text: "Something\nhappened  here"), "Something happened here")
        XCTAssertEqual(OpenRouter.youtubeQuery(title: "Same", text: "same"), "Same", "no repeated words")
        XCTAssertNil(OpenRouter.youtubeQuery(title: " ", text: ""))
        XCTAssertEqual(none.action(for: note("com.google.android.youtube")), web("https://www.youtube.com/"))
        let long = String(repeating: "abc ", count: 100)
        XCTAssertLessThanOrEqual(OpenRouter.youtubeQuery(title: "", text: long)!.count, 120)
    }

    // MARK: Spotify

    func testSpotifyTrack() {
        let media = NotificationMedia(title: "Midnight City", artist: "M83", mediaId: "spotify:track:6dGnYIeXmHdcikdzNNDMm2")
        let n = note("com.spotify.music", title: "Midnight City", text: "M83", media: media)
        XCTAssertEqual(none.action(for: n), web("https://open.spotify.com/track/6dGnYIeXmHdcikdzNNDMm2"))
        XCTAssertEqual(router("com.spotify.client").action(for: n),
                       .macApp(bundleID: "com.spotify.client", url: URL(string: "spotify:track:6dGnYIeXmHdcikdzNNDMm2")!,
                               fallback: URL(string: "https://open.spotify.com/track/6dGnYIeXmHdcikdzNNDMm2")))
    }

    func testSpotifyWithoutATrackOpensOnPhone() {
        XCTAssertEqual(none.action(for: note("com.spotify.music", title: "Podcast", text: "New episode")), .phone(key: "k1"))
        let episode = NotificationMedia(title: "T", artist: "A", mediaId: "spotify:episode:abc")
        XCTAssertEqual(router("com.spotify.client").action(for: note("com.spotify.music", media: episode)), .phone(key: "k1"))
        let url = NotificationMedia(title: "T", artist: "A", mediaId: "https://open.spotify.com/track/abc")
        XCTAssertEqual(none.action(for: note("com.spotify.music", media: url)), .phone(key: "k1"))
        XCTAssertNil(none.plan(for: note("com.spotify.music")).web, "no Open on web without a track")
    }

    func testSpotifyTrackIdIsValidated() {
        XCTAssertEqual(OpenRouter.spotifyTrackID("spotify:track:abc123"), "abc123")
        XCTAssertNil(OpenRouter.spotifyTrackID("spotify:track:"))
        XCTAssertNil(OpenRouter.spotifyTrackID("spotify:track:a/b?c=d"))
        XCTAssertNil(OpenRouter.spotifyTrackID("spotify:track:abc def"))
        XCTAssertNil(OpenRouter.spotifyTrackID(nil))
    }

    // MARK: Shopping, food and rides

    func testAmazonUsesTheRegionalHost() {
        XCTAssertEqual(none.action(for: note("in.amazon.mShop.android.shopping", title: "Delivered")), web("https://www.amazon.in/gp/css/order-history"))
        XCTAssertEqual(none.action(for: note("com.amazon.mShop.android.shopping", title: "Delivered")), web("https://www.amazon.com/gp/css/order-history"))
        XCTAssertEqual(none.action(for: note("in.amazon.mshop.android.shopping")), web("https://www.amazon.in/gp/css/order-history"))
    }

    func testSwiggyZomatoUber() {
        XCTAssertEqual(none.action(for: note("in.swiggy.android", title: "Order on the way")), web("https://www.swiggy.com/my-account/orders"))
        XCTAssertEqual(none.action(for: note("com.application.zomato", title: "Order on the way")), web("https://www.zomato.com/"))
        XCTAssertEqual(none.action(for: note("com.ubercab", title: "Your driver is here")), web("https://riders.uber.com/trips"))
    }

    // MARK: Preferences

    func testPreferences() {
        let n = note("com.twitter.android", title: "Maya", text: "liked your post")
        XCTAssertEqual(none.action(for: n, preference: .default), web("https://x.com/notifications"))
        XCTAssertEqual(none.action(for: n, preference: .phone), .phone(key: "k1"))
        XCTAssertEqual(none.action(for: n, preference: .web), web("https://x.com/notifications"))
        XCTAssertEqual(none.action(for: n, preference: .nothing), .none)
        // "Open on web" with no web page falls back to what a click would normally do.
        let s = note("com.slack", title: "x")
        XCTAssertEqual(none.action(for: s, preference: .web), .phone(key: "k1"))
        // With the Mac app installed, "Open on web" still means the browser.
        let w = note("com.whatsapp", title: "Maya", message: true, phone: "+15551230001")
        XCTAssertEqual(router("net.whatsapp.WhatsApp").action(for: w, preference: .web), web("https://web.whatsapp.com/send?phone=15551230001"))
    }

    func testWebRulesAndSummaries() {
        for pkg in ["com.google.android.gm", "com.whatsapp", "org.telegram.messenger", "com.twitter.android", "com.instagram.android", "com.linkedin.android",
                    "com.google.android.youtube", "com.spotify.music", "in.amazon.mShop.android.shopping", "in.swiggy.android", "com.application.zomato", "com.ubercab"] {
            XCTAssertTrue(none.hasWebRule(forPackage: pkg), pkg)
            XCTAssertNotEqual(none.summary(forPackage: pkg), "Opens on your phone", pkg)
        }
        XCTAssertFalse(none.hasWebRule(forPackage: "com.slack"))
        XCTAssertEqual(none.summary(forPackage: "com.slack"), "Opens on your phone")
        XCTAssertTrue(none.summary(forPackage: "com.twitter.android").contains("x.com/notifications"))
    }

    // MARK: Search

    func testSearchURL() {
        let n = note("com.slack", title: "  Sam  ", text: "uploaded v3 &\nthe flow ")
        XCTAssertEqual(OpenRouter.searchURL(for: n)?.absoluteString, "https://www.google.com/search?q=Sam%20uploaded%20v3%20%26%20the%20flow")
        XCTAssertNil(OpenRouter.searchURL(for: note("com.slack")))
        var otp = note("com.google.android.apps.messaging", title: "HDFC", text: "482196 is your OTP")
        otp.otp = OneTimeCode(code: "482196")
        XCTAssertNil(OpenRouter.searchURL(for: otp), "never search for a verification code")
        XCTAssertEqual(none.plan(for: n).search, OpenRouter.searchURL(for: n))
        let long = note("com.slack", title: "t", text: String(repeating: "word ", count: 100))
        XCTAssertLessThanOrEqual(OpenRouter.searchURL(for: long)!.absoluteString.count, 200 * 3 + 40)
    }

    func testEveryBuiltInRuleHasAPackageAndAStep() {
        var seen = Set<String>()
        for r in OpenRule.builtIn {
            XCTAssertFalse(r.packages.isEmpty, r.id); XCTAssertFalse(r.steps.isEmpty, r.id)
            XCTAssertEqual(r.steps.last?.when, .always, "\(r.id) must always give an answer")
            for p in r.packages { XCTAssertTrue(seen.insert(p.lowercased()).inserted, "\(p) is in two rules") }
        }
    }
}

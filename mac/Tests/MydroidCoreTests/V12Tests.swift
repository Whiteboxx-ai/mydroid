import XCTest
@testable import MydroidCore

final class V12ModelTests: XCTestCase {
    func testSettingsWireAndLegacyDecode() throws {
        var s = SyncSettings()
        s.mutedApps = ["com.b", "com.a"]; s.pauseBelowBattery = 20; s.screenshots = false
        let f = s.wireFields
        XCTAssertEqual(f["mutedApps"] as? [String], ["com.a", "com.b"])
        XCTAssertEqual(f["pauseBelowBattery"] as? Int, 20)
        XCTAssertEqual(f["screenshots"] as? Bool, false)
        XCTAssertEqual(f["smsHistory"] as? Bool, false)
        XCTAssertEqual(f["media"] as? Bool, true)
        XCTAssertTrue(SyncSettings().wireFields["pauseBelowBattery"] is NSNull)
        // Settings saved by an older build.
        let old = Data(#"{"notifications":false,"photos":true,"calls":true,"clipboard":true}"#.utf8)
        let d = try JSONDecoder().decode(SyncSettings.self, from: old)
        XCTAssertEqual(d.notifications, false)
        XCTAssertEqual(d.clipboard, true)
        XCTAssertEqual(d.mutedApps, [])
        XCTAssertEqual(d.screenshots, true)
        XCTAssertNil(d.pauseBelowBattery)
        let round = try JSONDecoder().decode(SyncSettings.self, from: try JSONEncoder().encode(s))
        XCTAssertEqual(round, s)
    }

    func testMediaExtrapolation() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var m = MediaState(title: "T", playing: true, position: 10_000, duration: 100_000, ts: t0)
        XCTAssertEqual(m.position(at: t0), 10_000)
        XCTAssertEqual(m.position(at: t0.addingTimeInterval(5)), 15_000)
        XCTAssertEqual(m.position(at: t0.addingTimeInterval(500)), 100_000, "clamped to duration")
        XCTAssertEqual(m.position(at: t0.addingTimeInterval(-3)), 10_000, "never goes backwards")
        XCTAssertEqual(m.fraction(at: t0.addingTimeInterval(40)), 0.5, accuracy: 0.0001)
        m.playing = false
        XCTAssertEqual(m.position(at: t0.addingTimeInterval(30)), 10_000, "paused does not advance")
    }

    func testMediaParsing() {
        XCTAssertNil(MediaState(message: Message("media.state", ["active": false])))
        let m = MediaState(message: Message("media.state", [
            "active": true, "pkg": "com.spotify.music", "app": "Spotify", "title": "Song", "artist": "Band", "album": "LP",
            "playing": true, "position": 5000, "duration": 200_000, "ts": 1_700_000_000_000, "canSeek": true, "canNext": true, "canPrev": false]))
        XCTAssertEqual(m?.title, "Song")
        XCTAssertEqual(m?.ts, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(m?.canPrev, false)
        XCTAssertNil(m?.art)
    }

    func testLowBatteryFiresOncePerDischarge() {
        var t = LowBatteryTracker()
        XCTAssertFalse(t.update(battery: 45, charging: false))
        XCTAssertTrue(t.update(battery: 19, charging: false))
        XCTAssertFalse(t.update(battery: 18, charging: false), "only one banner")
        XCTAssertFalse(t.update(battery: 17, charging: false))
        XCTAssertFalse(t.update(battery: 10, charging: true), "never while charging")
        XCTAssertTrue(t.update(battery: 15, charging: false), "re-armed after charging")
        var u = LowBatteryTracker()
        XCTAssertFalse(u.update(battery: 5, charging: true))
        XCTAssertFalse(u.update(battery: 20, charging: false), "20% is not below 20%")
    }

    func testLinkPolicy() {
        XCTAssertNotNil(LinkPolicy.parse("https://example.com/a?b=1"))
        XCTAssertNotNil(LinkPolicy.parse("http://example.com"))
        XCTAssertNotNil(LinkPolicy.parse("mailto:a@b.co"))
        XCTAssertNil(LinkPolicy.parse("file:///etc/passwd"))
        XCTAssertNil(LinkPolicy.parse("javascript:alert(1)"))
        XCTAssertNil(LinkPolicy.parse("tel:+15551234"))
        XCTAssertNil(LinkPolicy.parse("https://"))
        XCTAssertNil(LinkPolicy.parse("two words https://a.com"))
        XCTAssertNil(LinkPolicy.parse("mailto:"))
    }

    func testSendPayload() {
        XCTAssertEqual(SendPayload.classify(text: " https://example.com/x \n"), .link(URL(string: "https://example.com/x")!))
        XCTAssertEqual(SendPayload.classify(text: "hello world"), .text("hello world"))
        XCTAssertEqual(SendPayload.classify(text: "see https://example.com"), .text("see https://example.com"))
        XCTAssertNil(SendPayload.classify(text: "   "))
        XCTAssertEqual(SendPayload.parse(schemeURL: URL(string: "mydroid://send?url=https%3A%2F%2Fexample.com%2Fa")!), .link(URL(string: "https://example.com/a")!))
        XCTAssertEqual(SendPayload.parse(schemeURL: URL(string: "mydroid://send?text=hi%20there")!), .text("hi there"))
        XCTAssertEqual(SendPayload.parse(schemeURL: URL(string: "mydroid://send?file=/tmp/a%20b.txt")!), .files([URL(fileURLWithPath: "/tmp/a b.txt")]))
        XCTAssertNil(SendPayload.parse(schemeURL: URL(string: "mydroid://send?url=file%3A%2F%2F%2Fetc%2Fpasswd")!))
        XCTAssertNil(SendPayload.parse(schemeURL: URL(string: "mydroid://send?file=relative.txt")!))
        XCTAssertNil(SendPayload.parse(schemeURL: URL(string: "mydroid://other?text=x")!))
        XCTAssertNil(SendPayload.parse(schemeURL: URL(string: "other://send?text=x")!))
    }

    func testQuietHours() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        func at(_ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2025, month: 1, day: 1, hour: h, minute: m))! }
        var q = QuietHours(enabled: true, from: 22 * 60, to: 7 * 60)
        XCTAssertTrue(q.contains(at(23), calendar: cal))
        XCTAssertTrue(q.contains(at(3), calendar: cal))
        XCTAssertTrue(q.contains(at(22), calendar: cal))
        XCTAssertFalse(q.contains(at(7), calendar: cal))
        XCTAssertFalse(q.contains(at(12), calendar: cal))
        q = QuietHours(enabled: true, from: 13 * 60, to: 14 * 60 + 30)
        XCTAssertTrue(q.contains(at(14, 10), calendar: cal))
        XCTAssertFalse(q.contains(at(14, 30), calendar: cal))
        q.enabled = false
        XCTAssertFalse(q.contains(at(13, 30), calendar: cal))
    }

    func testKnownAppsAndScreenshots() {
        var k = KnownApps()
        XCTAssertTrue(k.note(PhoneNotification(key: "1", pkg: "com.whatsapp", app: "WhatsApp")))
        XCTAssertFalse(k.note(PhoneNotification(key: "2", pkg: "com.whatsapp", app: "WhatsApp")))
        XCTAssertTrue(k.note(PhoneNotification(key: "3", pkg: "com.slack", app: "com.slack", icon: Data([1]))))
        XCTAssertEqual(k.sorted().map(\.entry.name), ["Slack", "WhatsApp"])
        XCTAssertTrue(Screenshots.isScreenshot(name: "Screenshot_20250101-120000.png"))
        XCTAssertFalse(Screenshots.isScreenshot(name: "IMG_0001.jpg"))
    }

    func testClipboardSensitiveTypes() {
        XCTAssertTrue(ClipboardGuard.isSensitive(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        XCTAssertTrue(ClipboardGuard.isSensitive(types: ["org.nspasteboard.TransientType"]))
        XCTAssertFalse(ClipboardGuard.isSensitive(types: ["public.utf8-plain-text"]))
    }
}

final class V12LoopbackTests: XCTestCase {
    func testMediaLinksSettingsAndMute() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mydroid-v12-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileKeyValueStore(directory: dir.appendingPathComponent("secrets"))
        // Pair directly through the identity store so the test starts from a connected phone.
        let ltk = MydroidCrypto.randomBytes(32)
        let identity = Identity(store: store)
        identity.savePairing(phoneId: "phone-1", ltk: ltk, phoneName: "Pixel 9")
        let hub = Hub(HubConfiguration(macName: "Test Mac", identity: identity, config: store,
                                       ledgerURL: dir.appendingPathComponent("ledger.json"),
                                       photosDirectory: dir.appendingPathComponent("Pictures"),
                                       downloadsDirectory: dir.appendingPathComponent("Downloads"),
                                       preferredPort: 0, advertiseBonjour: false))
        let links = LinkBox()
        hub.onEvent = { if case let .linkOpen(u) = $0 { links.add(u) } }
        let port = try XCTUnwrap(hub.startAndWait())
        defer { hub.stop() }
        XCTAssertEqual(hub.snapshot.bleUUID, MydroidCrypto.bleUUID(ltk: ltk), "presence UUID is known as soon as paired")

        let c = TestClient(port: port)
        try await c.connect()
        try await c.handshake(phoneId: "phone-1", macId: hub.macId, ltk: ltk, pairing: false)
        let s0 = try await c.receive(type: "settings")
        XCTAssertEqual(s0.bool("media"), true)
        XCTAssertEqual(s0.bool("screenshots"), true)
        XCTAssertEqual(s0.bool("smsHistory"), false)
        XCTAssertEqual(s0.array("mutedApps")?.count ?? 0, 0)
        XCTAssertNotNil(s0.fields["pauseBelowBattery"], "present, null when never")

        // Settings change goes out immediately.
        var s = hub.snapshot.settings
        s.mutedApps = ["com.noisy"]; s.pauseBelowBattery = 30
        hub.setSettings(s)
        let s1 = try await c.receive(type: "settings")
        XCTAssertEqual(s1.fields["mutedApps"] as? [String], ["com.noisy"])
        XCTAssertEqual(s1.int("pauseBelowBattery"), 30)

        // Muted apps are dropped; others come through.
        try await c.send(Message("notif.posted", ["key": "m", "pkg": "com.noisy", "app": "Noisy", "title": "t", "text": "x", "when": 1_700_000_000_000]))
        try await c.send(Message("notif.posted", ["key": "ok", "pkg": "com.quiet", "app": "Quiet", "title": "t", "text": "x", "when": 1_700_000_000_000]))
        try await c.send(Message("device.status", ["battery": 18, "charging": false, "network": "wifi", "name": "Pixel 9", "model": "Pixel 9", "lowPowerMode": true]))
        try await c.send(Message("ping")); _ = try await c.receive(type: "pong")
        XCTAssertEqual(hub.snapshot.notifications.items.map(\.key), ["ok"])
        XCTAssertEqual(hub.snapshot.phone?.lowPowerMode, true)
        XCTAssertEqual(hub.snapshot.phone?.battery, 18)

        // Now playing: art is kept while the track is unchanged.
        let art = Data([1, 2, 3]).base64EncodedString()
        try await c.send(Message("media.state", ["active": true, "pkg": "p", "app": "Spotify", "title": "A", "artist": "B", "art": art,
                                                 "playing": true, "position": 1000, "duration": 60_000, "ts": 1_700_000_000_000]))
        try await c.send(Message("media.state", ["active": true, "pkg": "p", "app": "Spotify", "title": "A", "artist": "B",
                                                 "playing": false, "position": 2000, "duration": 60_000, "ts": 1_700_000_001_000]))
        try await c.send(Message("ping")); _ = try await c.receive(type: "pong")
        XCTAssertEqual(hub.snapshot.media?.art, Data([1, 2, 3]))
        XCTAssertEqual(hub.snapshot.media?.playing, false)
        hub.mediaCommand("next")
        do { let m = try await c.receive(type: "media.cmd"); XCTAssertEqual(m.string("action"), "next") }
        hub.mediaCommand("seek", position: 4200)
        let seek = try await c.receive(type: "media.cmd")
        XCTAssertEqual(seek.string("action"), "seek"); XCTAssertEqual(seek.int("position"), 4200)
        try await c.send(Message("media.state", ["active": false]))
        try await c.send(Message("ping")); _ = try await c.receive(type: "pong")
        XCTAssertNil(hub.snapshot.media)

        // Links: phone to Mac only for allowed schemes; Mac to phone likewise.
        try await c.send(Message("link.open", ["url": "file:///etc/passwd"]))
        try await c.send(Message("link.open", ["url": "https://example.com/hi"]))
        try await c.send(Message("ping")); _ = try await c.receive(type: "pong")
        XCTAssertEqual(links.all, [URL(string: "https://example.com/hi")!])
        XCTAssertTrue(hub.sendLink(URL(string: "https://example.org/x")!))
        do { let m = try await c.receive(type: "link.open"); XCTAssertEqual(m.string("url"), "https://example.org/x") }
        XCTAssertFalse(hub.sendLink(URL(string: "file:///etc/hosts")!))

        // Explicit text goes through even though clipboard sync is off.
        XCTAssertFalse(hub.snapshot.settings.clipboard)
        XCTAssertTrue(hub.sendText("hello"))
        do { let m = try await c.receive(type: "clip.set"); XCTAssertEqual(m.string("text"), "hello") }
        c.drop()
    }
}

private final class LinkBox: @unchecked Sendable {
    private let lock = NSLock(); private var urls: [URL] = []
    func add(_ u: URL) { lock.lock(); urls.append(u); lock.unlock() }
    var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
}

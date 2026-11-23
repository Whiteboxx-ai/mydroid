import XCTest
@testable import MydroidCore

// v1.8: camera import of Google Authenticator exports (PROTOCOL.md 14.4) and Continue on Mac (PROTOCOL.md 15).
// All payloads are synthetic. Nothing here touches a phone, Spotify or a camera.

/// Builds synthetic `otpauth-migration://` URIs with the same wire format as Google Authenticator's export.
enum MigrationFixture {
    static func payload(size: Int?, index: Int?, id: Int64?, accounts: Int = 2, version: Int? = 1) -> Data {
        var w = PBWriter()
        for n in 0..<accounts {
            var p = PBWriter()
            p.bytes(1, Data((0..<10).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ n) }))   // secret (never read back)
            p.string(2, "user\(n)@example.com")
            p.string(3, "Issuer\(n)")
            p.varint(4, 1); p.varint(5, 1); p.varint(6, 2)
            w.message(1, p.data)
        }
        if let version { w.int(2, Int64(version)) }
        if let size { w.int(3, Int64(size)) }
        if let index { w.int(4, Int64(index)) }
        if let id { w.int(5, id) }
        return w.data
    }

    static func uri(size: Int?, index: Int?, id: Int64?, accounts: Int = 2, escaped: Bool = true) -> String {
        let b64 = payload(size: size, index: index, id: id, accounts: accounts).base64EncodedString()
        let data = escaped ? b64.replacingOccurrences(of: "+", with: "%2B").replacingOccurrences(of: "/", with: "%2F").replacingOccurrences(of: "=", with: "%3D") : b64
        return "otpauth-migration://offline?data=" + data
    }

    static let single = "otpauth://totp/Example:me@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example"
}

final class MigrationBatchTests: XCTestCase {
    func testReadsBatchFieldsAndCountsAccountsOnly() throws {
        let info = try XCTUnwrap(MigrationInfo(uri: MigrationFixture.uri(size: 3, index: 1, id: 987_654, accounts: 4)))
        XCTAssertEqual(info, MigrationInfo(batchSize: 3, batchIndex: 1, batchId: 987_654, accountCount: 4))
    }

    func testNegativeBatchIdAndSignExtension() throws {
        let info = try XCTUnwrap(MigrationInfo(uri: MigrationFixture.uri(size: 2, index: 0, id: -1_234_567_890)))
        XCTAssertEqual(info.batchId, -1_234_567_890)
    }

    func testSingleExportWithoutBatchFields() throws {
        let info = try XCTUnwrap(MigrationInfo(uri: MigrationFixture.uri(size: nil, index: nil, id: nil, accounts: 1)))
        XCTAssertEqual(info.batchSize, 1)
        XCTAssertEqual(info.batchIndex, 0)
    }

    func testBase64Variants() throws {
        // Unescaped base64 with +, / and padding, and the URL-safe alphabet, both read the same.
        for escaped in [true, false] {
            for id in [Int64(1), 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 99_999] {
                let info = MigrationInfo(uri: MigrationFixture.uri(size: 2, index: 1, id: id, escaped: escaped))
                XCTAssertEqual(info?.batchId, id)
            }
        }
        let b64 = MigrationFixture.payload(size: 2, index: 1, id: 5).base64EncodedString()
        let urlSafe = b64.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(MigrationInfo(uri: "otpauth-migration://offline?data=" + urlSafe)?.batchSize, 2)
    }

    func testRejectsGarbage() {
        XCTAssertNil(MigrationInfo(uri: "otpauth-migration://offline"))
        XCTAssertNil(MigrationInfo(uri: "otpauth-migration://offline?data="))
        XCTAssertNil(MigrationInfo(uri: "otpauth-migration://offline?data=!!!not-base64!!!"))
        // Truncated protobuf: a length that runs past the end.
        var w = PBWriter(); w.tag(1, wire: 2); w.rawVarint(500); w.raw(Data([1, 2, 3]))
        XCTAssertNil(MigrationInfo(uri: "otpauth-migration://offline?data=" + w.data.base64EncodedString()))
        // No accounts at all is not an export.
        var empty = PBWriter(); empty.int(3, 2); empty.int(4, 0); empty.int(5, 1)
        XCTAssertNil(MigrationInfo(uri: "otpauth-migration://offline?data=" + empty.data.base64EncodedString()))
        // A varint that never ends.
        XCTAssertNil(MigrationInfo.scan(Data(repeating: 0xff, count: 20)))
    }

    func testSkipsFieldsItDoesNotKnow() throws {
        var w = PBWriter()
        var p = PBWriter(); p.string(2, "a"); w.message(1, p.data)
        w.raw(Data([0x4d, 1, 2, 3, 4]))                 // field 9, fixed32
        w.raw(Data([0x51, 1, 2, 3, 4, 5, 6, 7, 8]))     // field 10, fixed64
        w.int(3, 2); w.int(4, 1); w.int(5, 42)
        let info = try XCTUnwrap(MigrationInfo.scan(w.data))
        XCTAssertEqual(info.batchSize, 2); XCTAssertEqual(info.batchIndex, 1); XCTAssertEqual(info.batchId, 42)
    }

    func testClassify() {
        XCTAssertEqual(ScanPayload.classify(MigrationFixture.single), .single)
        XCTAssertEqual(ScanPayload.classify("OTPAUTH://hotp/x?secret=ABC&counter=1"), .single)
        XCTAssertEqual(ScanPayload.classify("https://example.com/otpauth://"), .other)
        XCTAssertEqual(ScanPayload.classify("WIFI:S:home;T:WPA;P:secret;;"), .other)
        XCTAssertEqual(ScanPayload.classify("otpauth://steam/x"), .other)
        XCTAssertEqual(ScanPayload.classify("otpauth-migration://offline?data=zzz"), .damaged)
        XCTAssertEqual(ScanPayload.classify(String(repeating: "a", count: ScanPayload.maxLength + 1)), .other)
        if case .migration(let i) = ScanPayload.classify(MigrationFixture.uri(size: 3, index: 0, id: 7)) { XCTAssertEqual(i.batchSize, 3) }
        else { XCTFail("migration code not recognised") }
    }
}

final class ImportTrackerTests: XCTestCase {
    let a = MigrationFixture.uri(size: 3, index: 0, id: 100)
    let b = MigrationFixture.uri(size: 3, index: 1, id: 100)
    let c = MigrationFixture.uri(size: 3, index: 2, id: 100)

    func testThreePartsOutOfOrderWithRepeatedFrames() {
        var t = ImportTracker()
        XCTAssertEqual(t.ingest(c), .accepted(scanned: 1, of: 3))
        XCTAssertEqual(t.ingest(c), .duplicate, "the same QR in the next frames")
        XCTAssertEqual(t.ingest(c), .duplicate)
        XCTAssertEqual(t.ingest(a), .accepted(scanned: 2, of: 3))
        XCTAssertEqual(t.ingest(a), .duplicate)
        XCTAssertEqual(t.scanned, 2); XCTAssertEqual(t.total, 3)
        XCTAssertEqual(t.ingest(b), .complete([a, b, c]), "sent in batch order")
        XCTAssertFalse(t.inProgress, "everything is dropped once complete")
        XCTAssertEqual(t.scanned, 0)
    }

    func testSingleCodes() {
        var t = ImportTracker()
        XCTAssertEqual(t.ingest(MigrationFixture.single), .complete([MigrationFixture.single]))
        let one = MigrationFixture.uri(size: 1, index: 0, id: 9)
        XCTAssertEqual(t.ingest(one), .complete([one]))
        let noBatch = MigrationFixture.uri(size: nil, index: nil, id: nil)
        XCTAssertEqual(t.ingest(noBatch), .complete([noBatch]))
    }

    func testOtherCodesAreIgnoredAndDoNotDisturbProgress() {
        var t = ImportTracker()
        XCTAssertEqual(t.ingest(a), .accepted(scanned: 1, of: 3))
        XCTAssertEqual(t.ingest("https://example.com"), .notForUs)
        XCTAssertEqual(t.ingest("WIFI:S:x;T:WPA;P:y;;"), .notForUs)
        XCTAssertEqual(t.ingest(""), .notForUs)
        XCTAssertEqual(t.scanned, 1)
    }

    func testSingleCodeDuringBatchAsksToFinishFirst() {
        var t = ImportTracker()
        _ = t.ingest(a)
        XCTAssertEqual(t.ingest(MigrationFixture.single), .finishBatchFirst)
        XCTAssertEqual(t.scanned, 1)
    }

    func testDifferentExportStartsOver() {
        var t = ImportTracker()
        _ = t.ingest(a); _ = t.ingest(b)
        let other = MigrationFixture.uri(size: 2, index: 0, id: 555)
        XCTAssertEqual(t.ingest(other), .restarted(scanned: 1, of: 2))
        XCTAssertEqual(t.ingest(MigrationFixture.uri(size: 2, index: 1, id: 555)), .complete([other, MigrationFixture.uri(size: 2, index: 1, id: 555)]))
    }

    func testBadPartNumbersAndDamagedCodes() {
        var t = ImportTracker()
        XCTAssertEqual(t.ingest(MigrationFixture.uri(size: 3, index: 3, id: 1)), .unreadable)
        XCTAssertEqual(t.ingest(MigrationFixture.uri(size: 3, index: -1, id: 1)), .unreadable)
        XCTAssertEqual(t.ingest(MigrationFixture.uri(size: 0, index: 0, id: 1)), .unreadable)
        XCTAssertEqual(t.ingest(MigrationFixture.uri(size: 500, index: 0, id: 1)), .unreadable)
        XCTAssertEqual(t.ingest("otpauth-migration://offline?data=%%%"), .unreadable)
        XCTAssertFalse(t.inProgress)
    }

    func testResetForgetsEverything() {
        var t = ImportTracker()
        _ = t.ingest(a); _ = t.ingest(b)
        t.reset()
        XCTAssertFalse(t.inProgress)
        XCTAssertEqual(t.ingest(a), .accepted(scanned: 1, of: 3), "the same code counts again after a reset")
    }
}

final class AuthImportBrokerTests: XCTestCase {
    func broker(_ t: FakeAuthTransport, timeout: TimeInterval = 5) -> AuthBroker {
        let b = AuthBroker(transport: t, codeTimeout: timeout, listTimeout: timeout, importTimeout: timeout)
        b.setConnected(true)
        return b
    }

    func testSendsAndReturnsResult() async throws {
        let t = FakeAuthTransport(); let b = broker(t)
        t.onSend = { m in
            b.handle(Message("auth.import.result", ["req": m.string("req") ?? "", "ok": true, "added": 3, "skipped": 1]))
        }
        let out = await b.importAccounts(uris: ["otpauth-migration://offline?data=AA", MigrationFixture.single])
        XCTAssertEqual(out, .added(added: 3, skipped: 1))
        XCTAssertEqual(t.sent.count, 1)
        XCTAssertEqual(t.sent[0].type, "auth.import")
        XCTAssertEqual(t.sent[0].fields["uris"] as? [String], ["otpauth-migration://offline?data=AA", MigrationFixture.single])
        XCTAssertFalse(String(describing: out).contains("otpauth"))
    }

    func testPhoneErrors() async {
        for (wire, expected) in [("cancelled", AuthImportOutcome.cancelled), ("locked", .locked), ("invalid", .invalid), ("weird", .failed)] {
            let t = FakeAuthTransport(); let b = broker(t)
            t.onSend = { m in b.handle(Message("auth.import.result", ["req": m.string("req") ?? "", "ok": false, "error": wire])) }
            let out = await b.importAccounts(uris: [MigrationFixture.single])
            XCTAssertEqual(out, expected, wire)
        }
    }

    func testOfflineEmptyAndTimeout() async {
        let t = FakeAuthTransport()
        let off = AuthBroker(transport: t)
        let a = await off.importAccounts(uris: [MigrationFixture.single])
        XCTAssertEqual(a, .offline)
        let b = broker(t)
        let e = await b.importAccounts(uris: [])
        XCTAssertEqual(e, .offline, "nothing to send")
        XCTAssertTrue(t.sent.isEmpty)
        let slow = broker(FakeAuthTransport(), timeout: 0.15)
        let r = await slow.importAccounts(uris: [MigrationFixture.single])
        XCTAssertEqual(r, .timeout)
    }

    func testDisconnectEndsTheWait() async {
        let t = FakeAuthTransport(); let b = broker(t)
        t.onSend = { _ in DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { b.setConnected(false) } }
        let out = await b.importAccounts(uris: [MigrationFixture.single])
        XCTAssertEqual(out, .offline)
    }

    func testCancelAndStrayReplies() async {
        let t = FakeAuthTransport(); let b = broker(t, timeout: 30)
        let task = Task { await b.importAccounts(uris: [MigrationFixture.single]) }
        try? await Task.sleep(for: .milliseconds(80))
        b.handle(Message("auth.import.result", ["req": "not-ours", "ok": true, "added": 9]))   // dropped
        task.cancel()
        let out = await task.value
        XCTAssertEqual(out, .cancelled)
        b.handle(Message("auth.import.result", ["req": t.sent.first?.string("req") ?? "x", "ok": true, "added": 1]))   // late: dropped
    }
}

final class MediaRefTests: XCTestCase {
    let id = "4uLU6hMCjMI75M1A2tKUQC"      // 22 base62 characters

    func testSpotifyURIs() {
        XCTAssertEqual(MediaRef(mediaId: "spotify:track:\(id)"), .spotify(.track, id: id))
        XCTAssertEqual(MediaRef(mediaId: " spotify:episode:\(id) "), .spotify(.episode, id: id))
        XCTAssertEqual(MediaRef(mediaId: "spotify:track:\(id)")?.spotifyURI, "spotify:track:\(id)")
    }

    func testUriToURL() {
        XCTAssertEqual(MediaRef(mediaId: "spotify:track:\(id)")?.webURL.absoluteString, "https://open.spotify.com/track/\(id)")
        XCTAssertEqual(MediaRef(mediaId: "spotify:episode:\(id)")?.webURL.absoluteString, "https://open.spotify.com/episode/\(id)")
    }

    func testWebLinks() {
        XCTAssertEqual(MediaRef(mediaId: "https://music.example.com/watch?v=1")?.webURL.absoluteString, "https://music.example.com/watch?v=1")
        XCTAssertNil(MediaRef(mediaId: "https://music.example.com/watch?v=1")?.spotifyURI)
        // An open.spotify.com link is the same item as its URI, and loses its tracking tail.
        for link in ["https://open.spotify.com/track/\(id)?si=abc123", "https://open.spotify.com/intl-de/track/\(id)", "http://open.spotify.com/track/\(id)"] {
            XCTAssertEqual(MediaRef(mediaId: link), .spotify(.track, id: id), link)
        }
        // Not a track page: stays a plain link.
        if case .web = MediaRef(mediaId: "https://open.spotify.com/artist/\(id)")! {} else { XCTFail("artist page should stay a link") }
    }

    func testRejects() {
        let bad: [String?] = [
            nil, "", "   ",
            "spotify:track:", "spotify:track:short", "spotify:track:\(id)x", "spotify:track:\(String(id.dropLast()))",
            "spotify:track:\(String(id.dropLast()))!", "spotify:track:\(String(id.dropLast()))-", "spotify:track:\(String(id.dropLast()))\u{FF11}",
            "spotify:artist:\(id)", "spotify:playlist:\(id)", "spotify:user:x:playlist:\(id)", "spotify:track:\(id):extra", "spotify:local:a:b:c:1",
            "spotify:track:\(String(id.dropLast()))\" & (do shell script \"x\") & \"",
            "spotify:track:\(id)\nspotify:track:\(id)", "spotify:track:\(id) \"",
            "ftp://example.com/x", "javascript:alert(1)", "file:///etc/passwd", "mailto:a@b.c", "http://", "https:///x", "example.com/x",
            "https://example.com/a b",
            "https://example.com/" + String(repeating: "a", count: 2100),
        ]
        for b in bad { XCTAssertNil(MediaRef(mediaId: b), b ?? "nil") }
    }

    func testFilteredIsCanonical() {
        XCTAssertEqual(MediaRef.filtered("  spotify:track:\(id) "), "spotify:track:\(id)")
        XCTAssertEqual(MediaRef.filtered("https://open.spotify.com/track/\(id)?si=1"), "spotify:track:\(id)")
        XCTAssertEqual(MediaRef.filtered("https://x.example/y"), "https://x.example/y")
        XCTAssertNil(MediaRef.filtered("spotify:track:nope"))
    }

    func testMediaStateKeepsOnlyAcceptableIds() {
        func state(_ mediaId: Any?) -> MediaState? {
            var f: [String: Any] = ["active": true, "title": "Song", "artist": "Band", "playing": true, "position": 1000, "duration": 60_000]
            if let mediaId { f["mediaId"] = mediaId }
            return MediaState(message: Message("media.state", f))
        }
        XCTAssertEqual(state("spotify:track:\(id)")?.mediaId, "spotify:track:\(id)")
        XCTAssertNil(state("spotify:track:evil\"")?.mediaId)
        XCTAssertNil(state(nil)?.mediaId)
        XCTAssertNil(state(42)?.mediaId)
    }
}

final class ContinueOnMacTests: XCTestCase {
    let id = "4uLU6hMCjMI75M1A2tKUQC"
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func media(playing: Bool, position: Int64, duration: Int64 = 200_000, id: String? = nil, title: String = "Song", artist: String = "Band") -> MediaState {
        MediaState(title: title, artist: artist, playing: playing, position: position, duration: duration, ts: t0, mediaId: id)
    }

    // MARK: Position

    func testPositionExtrapolatedWhilePlaying() {
        let m = media(playing: true, position: 10_000)
        XCTAssertEqual(ContinueOnMac.startSeconds(of: m, at: t0.addingTimeInterval(5)), 15.0, accuracy: 0.001)
        XCTAssertEqual(ContinueOnMac.startSeconds(of: m, at: t0), 10.0, accuracy: 0.001)
        XCTAssertEqual(ContinueOnMac.startSeconds(of: m, at: t0.addingTimeInterval(5.46)), 15.5, accuracy: 0.001, "rounded to a tenth")
    }

    func testPositionHeldWhilePaused() {
        XCTAssertEqual(ContinueOnMac.startSeconds(of: media(playing: false, position: 10_000), at: t0.addingTimeInterval(300)), 10.0, accuracy: 0.001)
    }

    func testPositionNeverPastTheEndOrBeforeTheStart() {
        let m = media(playing: true, position: 195_000)
        XCTAssertEqual(ContinueOnMac.startSeconds(of: m, at: t0.addingTimeInterval(60)), 200.0, accuracy: 0.001)
        XCTAssertEqual(ContinueOnMac.startSeconds(of: media(playing: true, position: 5_000), at: t0.addingTimeInterval(-30)), 5.0, accuracy: 0.001, "a clock that is behind adds nothing")
        XCTAssertEqual(ContinueOnMac.startSeconds(of: media(playing: true, position: -400), at: t0), 0, accuracy: 0.001)
        XCTAssertEqual(ContinueOnMac.startSeconds(of: media(playing: true, position: 5_000, duration: 0), at: t0.addingTimeInterval(2)), 7.0, accuracy: 0.001, "unknown duration")
    }

    // MARK: AppleScript

    func testEscape() {
        XCTAssertEqual(ContinueOnMac.appleScriptEscape("plain"), "plain")
        XCTAssertEqual(ContinueOnMac.appleScriptEscape("a\"b"), "a\\\"b")
        XCTAssertEqual(ContinueOnMac.appleScriptEscape("a\\b"), "a\\\\b")
        XCTAssertEqual(ContinueOnMac.appleScriptEscape("\\\""), "\\\\\\\"")
        XCTAssertEqual(ContinueOnMac.appleScriptEscape("a\nb\rc\td\u{0}e"), "abcde", "control characters are dropped")
        XCTAssertEqual(ContinueOnMac.appleScriptEscape("caf\u{E9} \u{1F3B5}"), "caf\u{E9} \u{1F3B5}")
    }

    func testDecimalIsLocaleIndependent() {
        XCTAssertEqual(ContinueOnMac.decimal(83.44), "83.4")
        XCTAssertEqual(ContinueOnMac.decimal(0), "0.0")
        XCTAssertEqual(ContinueOnMac.decimal(1234.5), "1234.5")
        XCTAssertEqual(ContinueOnMac.decimal(-3), "0.0")
    }

    func testScriptForATrack() throws {
        let s = try XCTUnwrap(ContinueOnMac.spotifyScript(uri: "spotify:track:\(id)", seconds: 83.4))
        XCTAssertTrue(s.hasPrefix("tell application id \"com.spotify.client\"\nplay track \"spotify:track:\(id)\"\n"))
        XCTAssertTrue(s.contains("set player position to 83.4\n"))
        XCTAssertTrue(s.hasSuffix("end tell"))
        XCTAssertEqual(s.filter { $0 == "\"" }.count, 4, "the only quotes are the two literals we wrote")
        let ep = try XCTUnwrap(ContinueOnMac.spotifyScript(uri: "spotify:episode:\(id)", seconds: 0))
        XCTAssertTrue(ep.contains("play track \"spotify:episode:\(id)\""))
        XCTAssertFalse(ep.contains("set player position"), "starting from the top needs no seek")
    }

    func testScriptRefusesAnythingThatIsNotACanonicalSpotifyURI() {
        let bad = [
            "spotify:track:\(String(id.dropLast()))\" & (do shell script \"say hi\") & \"",
            "spotify:track:\(id)\" & (do shell script \"say hi\")",
            "spotify:track:\(id)\ndo shell script \"x\"",
            "spotify:track:\(id)\\",
            "spotify:artist:\(id)", "spotify:track:short", "https://open.spotify.com/track/\(id)",
            "Spotify:Track:\(id)", " spotify:track:\(id)", "spotify:track:\(id) ", "",
        ]
        for u in bad { XCTAssertNil(ContinueOnMac.spotifyScript(uri: u, seconds: 10), u) }
    }

    // MARK: Search and the offer

    func testSearchURL() {
        XCTAssertEqual(ContinueOnMac.searchURL(title: "Blinding Lights", artist: "The Weeknd")?.absoluteString,
                       "https://www.google.com/search?q=Blinding%20Lights%20The%20Weeknd")
        XCTAssertEqual(ContinueOnMac.searchURL(title: "Rock & Roll", artist: "")?.absoluteString, "https://www.google.com/search?q=Rock%20%26%20Roll")
        XCTAssertEqual(ContinueOnMac.searchURL(title: "", artist: "Band")?.absoluteString, "https://www.google.com/search?q=Band")
        XCTAssertEqual(ContinueOnMac.searchURL(title: "a\nb  c", artist: " d ")?.absoluteString, "https://www.google.com/search?q=a%20b%20c%20d")
        XCTAssertNil(ContinueOnMac.searchURL(title: "", artist: ""))
        XCTAssertNil(ContinueOnMac.searchURL(title: "  ", artist: "\n"))
        let q = ContinueOnMac.searchURL(title: "\u{201C}x\u{201D}#&=+?", artist: "")!.absoluteString
        XCTAssertFalse(q.dropFirst("https://www.google.com/search?q=".count).contains(where: { "#&=+? \"".contains($0) }), "everything unsafe is escaped")
    }

    func testOffer() {
        XCTAssertEqual(ContinueOnMac.offer(for: media(playing: true, position: 0, id: "spotify:track:\(id)")), .continueOnMac(.spotify(.track, id: id)))
        guard case .searchWeb(let u)? = ContinueOnMac.offer(for: media(playing: true, position: 0)) else { return XCTFail("expected a search") }
        XCTAssertTrue(u.absoluteString.hasSuffix("q=Song%20Band"))
        XCTAssertNil(ContinueOnMac.offer(for: media(playing: true, position: 0, title: "", artist: "")))
    }
}

final class V18LoopbackTests: XCTestCase {
    private func connect() async throws -> (Hub, TestClient, () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mydroid-v18-\(UUID().uuidString)")
        let store = FileKeyValueStore(directory: dir.appendingPathComponent("secrets"))
        let ltk = MydroidCrypto.randomBytes(32)
        let identity = Identity(store: store)
        identity.savePairing(phoneId: "phone-1", ltk: ltk, phoneName: "Pixel 9")
        let hub = Hub(HubConfiguration(macName: "Test Mac", identity: identity, config: store,
                                       ledgerURL: dir.appendingPathComponent("ledger.json"),
                                       photosDirectory: dir.appendingPathComponent("Pictures"),
                                       downloadsDirectory: dir.appendingPathComponent("Downloads"),
                                       preferredPort: 0, advertiseBonjour: false))
        let port = try XCTUnwrap(hub.startAndWait())
        let c = TestClient(port: port)
        try await c.connect()
        try await c.handshake(phoneId: "phone-1", macId: hub.macId, ltk: ltk, pairing: false)
        _ = try await c.receive(type: "settings")
        return (hub, c, { hub.stop(); try? FileManager.default.removeItem(at: dir) })
    }

    func testMediaIdIsKeptWhileTheTrackIsUnchanged() async throws {
        let (hub, c, cleanup) = try await connect(); defer { cleanup() }
        let id = "4uLU6hMCjMI75M1A2tKUQC"
        func state(_ title: String, mediaId: String?, playing: Bool = true) -> Message {
            var f: [String: Any] = ["active": true, "pkg": "p", "app": "Spotify", "title": title, "artist": "B", "playing": playing,
                                    "position": 1000, "duration": 60_000, "ts": 1_700_000_000_000]
            if let mediaId { f["mediaId"] = mediaId }
            return Message("media.state", f)
        }
        func sync() async throws { try await c.send(Message("ping")); _ = try await c.receive(type: "pong") }
        try await c.send(state("A", mediaId: "spotify:track:\(id)")); try await sync()
        XCTAssertEqual(hub.snapshot.media?.mediaId, "spotify:track:\(id)")
        try await c.send(state("A", mediaId: nil, playing: false)); try await sync()
        XCTAssertEqual(hub.snapshot.media?.mediaId, "spotify:track:\(id)", "sent on track change only, so a pause keeps it")
        XCTAssertEqual(hub.snapshot.media?.playing, false)
        try await c.send(state("B", mediaId: nil)); try await sync()
        XCTAssertNil(hub.snapshot.media?.mediaId, "a different track without an id falls back to Search on web")
        try await c.send(state("C", mediaId: "spotify:track:bad\"")); try await sync()
        XCTAssertNil(hub.snapshot.media?.mediaId, "an id that fails the filter is dropped")
    }

    func testAuthImportRoundTripThroughTheHub() async throws {
        let (hub, c, cleanup) = try await connect(); defer { cleanup() }
        let uris = [MigrationFixture.uri(size: 2, index: 0, id: 7), MigrationFixture.uri(size: 2, index: 1, id: 7)]
        async let outcome = hub.auth.importAccounts(uris: uris)
        let m = try await c.receive(type: "auth.import")
        XCTAssertEqual(m.fields["uris"] as? [String], uris)
        let req = try XCTUnwrap(m.string("req"))
        try await c.send(Message("auth.import.result", ["req": req, "ok": true, "added": 4, "skipped": 0]))
        let got = await outcome
        XCTAssertEqual(got, .added(added: 4, skipped: 0))
    }
}

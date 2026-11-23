import XCTest
@testable import MydroidCore

final class PublicSuffixTests: XCTestCase {
    let psl = PublicSuffixList.shared

    func testRegistrableDomains() {
        let cases: [(String, String?)] = [
            ("login.salesforce.com", "salesforce.com"),
            ("foo.my.salesforce.com", "salesforce.com"),
            ("salesforce.com", "salesforce.com"),
            ("accounts.google.co.in", "google.co.in"),
            ("www.bbc.co.uk", "bbc.co.uk"),
            ("a.b.c.example.com.au", "example.com.au"),
            ("signin.aws.amazon.com", "amazon.com"),
            ("github.com", "github.com"),
            ("me.github.io", "me.github.io"),          // private suffix: a different person's site is a different domain
            ("x.y.herokuapp.com", "y.herokuapp.com"),
            ("www.ck", "www.ck"),                      // exception rule
            ("foo.bar.ck", "foo.bar.ck"),              // wildcard rule: bar.ck is the suffix
            ("LOGIN.Okta.COM.", "okta.com"),
            ("https://user@login.okta.com:8443/path?q=1", "okta.com"),
        ]
        for (host, want) in cases { XCTAssertEqual(psl.registrableDomain(of: host), want, host) }
    }

    func testNoRegistrableDomain() {
        for h in ["localhost", "co.uk", "com", "192.168.1.5", "10.0.0.1:8080", "", "[::1]"] {
            XCTAssertNil(psl.registrableDomain(of: h), h)
        }
    }

    func testPublicSuffixAndWithin() {
        XCTAssertEqual(psl.publicSuffix(of: "a.b.co.uk"), "co.uk")
        XCTAssertEqual(psl.publicSuffix(of: "something.unknowntld"), "unknowntld")
        XCTAssertTrue(PublicSuffixList.host("login.okta.com", isWithin: "okta.com"))
        XCTAssertTrue(PublicSuffixList.host("okta.com", isWithin: "okta.com"))
        XCTAssertFalse(PublicSuffixList.host("notokta.com", isWithin: "okta.com"))
        XCTAssertFalse(PublicSuffixList.host("okta.com.evil.io", isWithin: "okta.com"))
    }

    func testNormalizeHost() {
        XCTAssertEqual(PublicSuffixList.normalizeHost(" HTTPS://A.B.com:99/x "), "a.b.com")
        XCTAssertNil(PublicSuffixList.normalizeHost("a b.com"))
        XCTAssertNil(PublicSuffixList.normalizeHost("..com"))
        XCTAssertNil(PublicSuffixList.normalizeHost("   "))
    }
}

final class LookalikeTests: XCTestCase {
    let known = [KnownSite(issuer: "Salesforce", domains: ["salesforce.com", "force.com"]),
                 KnownSite(issuer: "PayPal", domains: ["paypal.com"]),
                 KnownSite(issuer: "Microsoft", domains: ["microsoft.com", "live.com"]),
                 KnownSite(issuer: "Google", domains: ["google.com"]),
                 KnownSite(issuer: "Apple", domains: ["apple.com"])]

    func kind(_ host: String) -> Lookalike.Kind? { LookalikeDetector.assess(host: host, known: known)?.kind }

    func testGenuineDomainsAreNotLookalikes() {
        for h in ["login.salesforce.com", "foo.my.salesforce.com", "salesforce.com", "na1.force.com", "www.paypal.com", "outlook.live.com"] {
            XCTAssertNil(kind(h), h)
        }
    }

    func testConfusableCharacters() {
        XCTAssertEqual(kind("paypa1.com"), .confusable)
        XCTAssertEqual(kind("g00gle.com"), .confusable)
        XCTAssertEqual(kind("rnicrosoft.com"), .confusable)
        XCTAssertEqual(kind("s\u{0430}lesforce.com"), .confusable)          // Cyrillic a
        XCTAssertEqual(kind("xn--80ak6aa92e.com"), .confusable)             // "аррӏе.com" spelled with Cyrillic letters
        XCTAssertEqual(kind("pay-pal.com"), .confusable)
    }

    func testTyposAndEmbedding() {
        XCTAssertEqual(kind("salesfroce.com"), .typo)
        XCTAssertEqual(kind("paypall.com"), .typo)
        XCTAssertEqual(kind("salesforce-login.com"), .containsName)
        XCTAssertEqual(kind("salesforce.com.evil.io"), .nameInSubdomain)
        XCTAssertEqual(kind("login.paypal.evil.example"), .nameInSubdomain)
        XCTAssertEqual(kind("salesforce.co"), .otherSuffix)
        XCTAssertEqual(kind("google.co.in"), .otherSuffix)
    }

    func testUnrelatedSitesAndEdgeCases() {
        for h in ["example.org", "wikipedia.org", "10.0.0.1", "localhost", "ab.com", ""] { XCTAssertNil(kind(h), h) }
        XCTAssertNil(LookalikeDetector.assess(host: "paypa1.com", known: []))
    }

    func testIssuerNameWithoutDomainStillCounts() {
        let k = [KnownSite(issuer: "Dropbox", domains: [])]
        XCTAssertEqual(LookalikeDetector.assess(host: "dr0pbox.com", known: k)?.kind, .confusable)
    }

    func testPunycodeAndEditDistance() {
        XCTAssertEqual(Punycode.decodeLabel("xn--bcher-kva"), "b\u{00FC}cher")
        XCTAssertEqual(Punycode.decodeLabel("plain"), "plain")
        XCTAssertEqual(LookalikeDetector.editDistance("kitten", "sitting"), 3)
        XCTAssertEqual(LookalikeDetector.editDistance("ab", "ba"), 1)
    }
}

final class FakeAuthTransport: AuthTransport {
    private let lock = NSLock()
    private var _sent: [Message] = []
    var sent: [Message] { lock.lock(); defer { lock.unlock() }; return _sent }
    var onSend: ((Message) -> Void)?
    func sendAuth(_ m: Message) { lock.lock(); _sent.append(m); lock.unlock(); onSend?(m) }
}

final class AuthBrokerTests: XCTestCase {
    func broker(_ t: FakeAuthTransport, timeout: TimeInterval = 5) -> AuthBroker {
        let b = AuthBroker(transport: t, codeTimeout: timeout, listTimeout: timeout)
        b.setConnected(true)
        return b
    }
    let request = AuthCodeRequest(domain: "salesforce.com", host: "login.salesforce.com", account: "me@work.com", client: "Chrome")

    func testCodecShapes() {
        let m = AuthCodec.codeGet(req: "r1", request)
        XCTAssertEqual(m.type, "auth.code.get")
        XCTAssertEqual(m.string("req"), "r1")
        XCTAssertEqual(m.string("domain"), "salesforce.com")
        XCTAssertEqual(m.string("host"), "login.salesforce.com")
        XCTAssertEqual(m.string("account"), "me@work.com")
        XCTAssertEqual(m.string("client"), "Chrome")
        XCTAssertNil(m.fields["entryId"])
        XCTAssertEqual(AuthCodec.codeGet(req: "r", AuthCodeRequest(domain: "a.com", host: "a.com", entryId: "e1", client: "x")).string("entryId"), "e1")
        XCTAssertEqual(AuthCodec.listGet(req: "r2").type, "auth.list.get")
        let d = AuthCodec.domainSet(entryId: "e1", domain: "okta.com")
        XCTAssertEqual(d.type, "auth.domain.set"); XCTAssertEqual(d.string("entryId"), "e1"); XCTAssertEqual(d.string("domain"), "okta.com")
        // The codec round-trips through the real wire encoding.
        let back = try! Message.decode(try! m.encode())
        XCTAssertEqual(back.string("host"), "login.salesforce.com")
    }

    func testDecodeOutcomes() {
        XCTAssertEqual(AuthCodec.decodeOutcome(Message("auth.code", ["ok": true, "code": "123456", "validFor": 12, "entryId": "e"])),
                       .code("123456", validFor: 12, entryId: "e"))
        for (err, want) in [("denied", AuthOutcome.denied), ("timeout", .timeout), ("no_match", .noMatch), ("locked", .locked), ("weird", .failed)] {
            XCTAssertEqual(AuthCodec.decodeOutcome(Message("auth.code", ["ok": false, "error": err])), want)
        }
        let amb = AuthCodec.decodeOutcome(Message("auth.code", ["ok": false, "error": "ambiguous",
                                                                 "choices": [["id": "1", "issuer": "Salesforce", "account": "a"], ["id": "2", "issuer": "Salesforce", "account": "b"]]]))
        XCTAssertEqual(amb, .ambiguous([AuthChoice(id: "1", issuer: "Salesforce", account: "a"), AuthChoice(id: "2", issuer: "Salesforce", account: "b")]))
        XCTAssertEqual(AuthCodec.decodeOutcome(Message("auth.code", ["ok": true])), .failed)
    }

    func testCodeRequestAwaitsMatchingReply() async {
        let t = FakeAuthTransport(); let b = broker(t)
        t.onSend = { m in
            guard m.type == "auth.code.get", let req = m.string("req") else { return }
            // An unrelated reply first (must be ignored), then the real one.
            b.handle(Message("auth.code", ["req": "someone-else", "ok": false, "error": "denied"]))
            b.handle(Message("auth.code", ["req": req, "ok": true, "code": "654321", "validFor": 20, "entryId": "e9"]))
        }
        let r = await b.requestCode(request)
        XCTAssertEqual(r, .code("654321", validFor: 20, entryId: "e9"))
        XCTAssertFalse("\(r)".contains("654321"), "descriptions never include the code")
    }

    func testPhoneErrorsPassThrough() async {
        let t = FakeAuthTransport(); let b = broker(t)
        t.onSend = { m in b.handle(Message("auth.code", ["req": m.string("req")!, "ok": false, "error": "denied"])) }
        let r = await b.requestCode(request)
        XCTAssertEqual(r, .denied)
    }

    func testTimesOutWithoutReply() async {
        let t = FakeAuthTransport(); let b = broker(t, timeout: 0.2)
        let started = Date()
        let r = await b.requestCode(request)
        XCTAssertEqual(r, .timeout)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testLateReplyAfterTimeoutIsIgnored() async {
        let t = FakeAuthTransport(); let b = broker(t, timeout: 0.1)
        let r = await b.requestCode(request)
        XCTAssertEqual(r, .timeout)
        let req = t.sent[0].string("req")!
        b.handle(Message("auth.code", ["req": req, "ok": true, "code": "111111", "validFor": 5]))   // must not crash or resume twice
    }

    func testOfflineAndDisconnect() async {
        let t = FakeAuthTransport()
        let b = AuthBroker(transport: t)
        let offline = await b.requestCode(request)
        XCTAssertEqual(offline, .offline)
        XCTAssertTrue(t.sent.isEmpty)
        b.setConnected(true)
        let pending = Task { await b.requestCode(request) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        b.setConnected(false)
        let dropped = await pending.value
        XCTAssertEqual(dropped, .offline)
    }

    func testCancellation() async {
        let t = FakeAuthTransport(); let b = broker(t, timeout: 30)
        let task = Task { await b.requestCode(request) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let r = await task.value
        XCTAssertEqual(r, .cancelled)
    }

    func testListIsCachedInMemoryAndClearedOnDisconnect() async {
        let t = FakeAuthTransport(); let b = broker(t)
        t.onSend = { m in
            guard m.type == "auth.list.get" else { return }
            b.handle(Message("auth.list", ["req": m.string("req")!, "items": [
                ["id": "1", "issuer": "Salesforce", "account": "me@work.com", "domains": ["salesforce.com"], "digits": 6],
                ["id": "2", "issuer": "GitHub", "account": "me", "domains": [String](), "digits": 8]]]))
        }
        let list = await b.fetchList()
        XCTAssertEqual(list?.count, 2)
        XCTAssertEqual(list?[1].digits, 8)
        XCTAssertEqual(b.cachedEntries.count, 2)
        XCTAssertTrue(b.setDomain(entryId: "2", domain: "github.com"))
        XCTAssertEqual(b.cachedEntries[1].domains, ["github.com"])
        XCTAssertEqual(t.sent.last?.type, "auth.domain.set")
        b.setConnected(false)
        XCTAssertTrue(b.cachedEntries.isEmpty)
        XCTAssertFalse(b.setDomain(entryId: "2", domain: "x.com"))
    }

    func testListTimesOutToNil() async {
        let t = FakeAuthTransport(); let b = broker(t, timeout: 0.15)
        let l = await b.fetchList()
        XCTAssertNil(l)
    }
}

final class FakeBridgeHost: OTPBridgeHost {
    var phoneConnected = true
    var sites = Set<String>()
    func autofillAllowed(domain: String) -> Bool { sites.contains(domain) }
    func setAutofill(domain: String, enabled: Bool) { if enabled { sites.insert(domain) } else { sites.remove(domain) } }
}

final class OTPBridgeTests: XCTestCase {
    func make(timeout: TimeInterval = 5) -> (OTPBridge, AuthBroker, FakeAuthTransport, FakeBridgeHost) {
        let t = FakeAuthTransport()
        let b = AuthBroker(transport: t, codeTimeout: timeout, listTimeout: timeout)
        b.setConnected(true)
        let h = FakeBridgeHost()
        return (OTPBridge(broker: b, host: h), b, t, h)
    }

    func testCodeUsesRegistrableDomainAndEchoesId() async {
        let (bridge, broker, t, _) = make()
        t.onSend = { m in broker.handle(Message("auth.code", ["req": m.string("req")!, "ok": true, "code": "424242", "validFor": 17, "entryId": "e1"])) }
        let r = await bridge.handle(["id": 7, "op": "code", "host": "https://Login.Salesforce.com/x", "account": "me@work.com", "client": "Chrome"])
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(r["code"] as? String, "424242")
        XCTAssertEqual(r["id"] as? Int, 7)
        let sent = t.sent[0]
        XCTAssertEqual(sent.string("domain"), "salesforce.com")
        XCTAssertEqual(sent.string("host"), "login.salesforce.com")
        XCTAssertEqual(sent.string("client"), "Chrome")
    }

    func testErrorsAndAmbiguous() async {
        let (bridge, broker, t, _) = make()
        t.onSend = { m in
            broker.handle(Message("auth.code", ["req": m.string("req")!, "ok": false, "error": "ambiguous",
                                                 "choices": [["id": "1", "issuer": "Okta", "account": "a"]]]))
        }
        let r = await bridge.handle(["op": "code", "host": "x.okta.com"])
        XCTAssertEqual(r["error"] as? String, "ambiguous")
        XCTAssertEqual((r["choices"] as? [[String: String]])?.first?["id"], "1")
        XCTAssertEqual(r["domain"] as? String, "okta.com")
        let bad = await bridge.handle(["op": "nope"])
        XCTAssertEqual(bad["error"] as? String, "bad_request")
        let noHost = await bridge.handle(["op": "code"])
        XCTAssertEqual(noHost["error"] as? String, "bad_request")
    }

    func testListWithLookalikeAndLinkConfirmation() async {
        let (bridge, broker, t, _) = make()
        t.onSend = { m in
            if m.type == "auth.list.get" {
                broker.handle(Message("auth.list", ["req": m.string("req")!, "items": [["id": "1", "issuer": "PayPal", "account": "me", "domains": ["paypal.com"], "digits": 6]]]))
            }
        }
        let list = await bridge.handle(["op": "list", "host": "paypa1.com"])
        XCTAssertEqual((list["lookalike"] as? [String: Any])?["resembles"] as? String, "paypal.com")
        XCTAssertNotNil(list["domain"])

        // Linking a lookalike needs an explicit acknowledgement; nothing is sent to the phone before that.
        let refused = await bridge.handle(["op": "link", "host": "paypa1.com", "entryId": "1"])
        XCTAssertEqual(refused["error"] as? String, "lookalike")
        XCTAssertFalse(t.sent.contains { $0.type == "auth.domain.set" })
        let ok = await bridge.handle(["op": "link", "host": "paypa1.com", "entryId": "1", "acknowledged": true])
        XCTAssertEqual(ok["ok"] as? Bool, true)
        XCTAssertEqual(t.sent.last?.type, "auth.domain.set")
        XCTAssertEqual(t.sent.last?.string("domain"), "paypa1.com")

        // An ordinary new site links straight away, with the registrable domain.
        let plain = await bridge.handle(["op": "link", "host": "accounts.example.org", "entryId": "1"])
        XCTAssertEqual(plain["domain"] as? String, "example.org")
        XCTAssertEqual(t.sent.last?.string("domain"), "example.org")
    }

    func testStatusAndAutofill() async {
        let (bridge, _, _, host) = make()
        let off = await bridge.handle(["op": "status", "host": "login.okta.com"])
        XCTAssertEqual(off["connected"] as? Bool, true)
        XCTAssertEqual(off["autofill"] as? Bool, false)
        _ = await bridge.handle(["op": "autofill", "host": "login.okta.com", "on": true])
        XCTAssertTrue(host.sites.contains("okta.com"))
        let on = await bridge.handle(["op": "status", "host": "other.okta.com"])
        XCTAssertEqual(on["autofill"] as? Bool, true)
        host.phoneConnected = false
        let down = await bridge.handle(["op": "status"])
        XCTAssertEqual(down["connected"] as? Bool, false)
        _ = await bridge.handle(["op": "autofill", "host": "okta.com", "on": false])
        XCTAssertTrue(host.sites.isEmpty)
    }

    func testOfflineMapsToError() async {
        let t = FakeAuthTransport()
        let b = AuthBroker(transport: t)
        let bridge = OTPBridge(broker: b, host: FakeBridgeHost())
        let r = await bridge.handle(["op": "code", "host": "okta.com"])
        XCTAssertEqual(r["error"] as? String, "offline")
        let l = await bridge.handle(["op": "list"])
        XCTAssertEqual(l["error"] as? String, "offline")
    }
}

/// The real Hub: an `auth.code.get` goes to the phone encrypted, and the phone's `auth.code` completes the request.
final class AuthHubLoopbackTests: XCTestCase {
    func testHubRoutesAuthMessages() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mydroid-auth-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileKeyValueStore(directory: dir.appendingPathComponent("state"))
        let identity = Identity(store: store)
        let ltk = MydroidCrypto.randomBytes(32)
        identity.savePairing(phoneId: "phone-1", ltk: ltk, phoneName: "Pixel 9")
        let hub = Hub(HubConfiguration(macName: "Mac", identity: identity, config: store, ledgerURL: dir.appendingPathComponent("l.json"),
                                       photosDirectory: dir.appendingPathComponent("p"), downloadsDirectory: dir.appendingPathComponent("d"),
                                       preferredPort: 0, advertiseBonjour: false))
        guard let port = hub.startAndWait() else { return XCTFail("no port") }
        defer { hub.stop() }
        let phone = TestClient(port: port)
        try await phone.connect()
        try await phone.handshake(phoneId: "phone-1", macId: hub.macId, ltk: ltk, pairing: false)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(hub.auth.isConnected)

        let task = Task { await hub.auth.requestCode(AuthCodeRequest(domain: "okta.com", host: "login.okta.com", client: "Chrome")) }
        let got = try await phone.receive(type: "auth.code.get")
        XCTAssertEqual(got.string("domain"), "okta.com")
        try await phone.send(Message("auth.code", ["req": got.string("req")!, "ok": true, "code": "135790", "validFor": 25, "entryId": "e1"]))
        let outcome = await task.value
        XCTAssertEqual(outcome, .code("135790", validFor: 25, entryId: "e1"))

        phone.drop()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(hub.auth.isConnected)
    }
}

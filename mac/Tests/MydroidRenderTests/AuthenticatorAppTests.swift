import XCTest
import SwiftUI
import AppKit
@testable import Mydroid
@testable import MydroidCore
@testable import MydroidNM

final class RecordingTransport: AuthTransport {
    private let lock = NSLock()
    private var _sent: [Message] = []
    var sent: [Message] { lock.lock(); defer { lock.unlock() }; return _sent }
    var onSend: ((Message) -> Void)?
    func sendAuth(_ m: Message) { lock.lock(); _sent.append(m); lock.unlock(); onSend?(m) }
}

final class Trust: AccessibilityChecking { var isTrusted = true }

/// The ⌃⌥C flow with every system piece faked: no browser is read, nothing is typed, nothing goes to a phone.
@MainActor
final class AuthShortcutFlowTests: XCTestCase {
    let chrome = FrontBrowser.match(bundleID: "com.google.Chrome")!
    var transport = RecordingTransport()
    var broker: AuthBroker!
    var browser = NullFrontBrowser()
    var typer = NullTyper()
    var hud = NullHUD()
    var trust = Trust()
    var explained = true
    var controller: AuthShortcutController!

    override func setUp() async throws {
        transport = RecordingTransport()
        broker = AuthBroker(transport: transport, codeTimeout: 5, listTimeout: 5)
        broker.setConnected(true)
        browser = NullFrontBrowser(); typer = NullTyper(); hud = NullHUD(); trust = Trust(); explained = true
        browser.app = .browser(chrome)
        browser.urls = [.url(URL(string: "https://login.salesforce.com/verify")!)]
        controller = AuthShortcutController(
            broker: broker, browsers: browser, typer: typer, accessibility: trust, hud: hud,
            hooks: .init(automationExplained: { [unowned self] in explained }, setAutomationExplained: { [unowned self] in explained = true }),
            finalDisplay: 0.05, openAccessibility: {}, openAutomation: {})
    }

    private func until(_ what: String = "", timeout: TimeInterval = 4, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond(), Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
    }

    private func reply(_ f: @escaping (Message) -> Message?) {
        transport.onSend = { [broker] m in if let r = f(m) { broker!.handle(r) } }
    }

    func testFillsWhenTheDomainStillMatches() async {
        reply { m in m.type == "auth.code.get" ? Message("auth.code", ["req": m.string("req")!, "ok": true, "code": "246810", "validFor": 20]) : nil }
        controller.trigger()
        await until("filled") { self.hud.states.contains(.filled(domain: "salesforce.com")) }
        XCTAssertEqual(typer.typed, ["246810"])
        let get = transport.sent[0]
        XCTAssertEqual(get.string("domain"), "salesforce.com")
        XCTAssertEqual(get.string("host"), "login.salesforce.com")
        XCTAssertEqual(get.string("client"), "Chrome via shortcut")
        XCTAssertTrue(hud.states.contains(.waiting(domain: "salesforce.com")))
    }

    func testDeniedTimedOutAndLockedTypeNothing() async {
        for (err, want) in [("denied", AuthHUDState.denied), ("timeout", .timedOut), ("locked", .locked)] {
            hud = NullHUD(); typer = NullTyper()
            controller = AuthShortcutController(broker: broker, browsers: browser, typer: typer, accessibility: trust, hud: hud,
                                                hooks: .init(automationExplained: { true }, setAutomationExplained: {}), finalDisplay: 0.05,
                                                openAccessibility: {}, openAutomation: {})
            reply { m in m.type == "auth.code.get" ? Message("auth.code", ["req": m.string("req")!, "ok": false, "error": err]) : nil }
            controller.trigger()
            await until(err) { self.hud.states.contains(want) }
            XCTAssertTrue(typer.typed.isEmpty, err)
            await until("run ended") { !self.controller.isRunning }
        }
    }

    func testPageChangedDuringApprovalTypesNothing() async {
        browser.urls = [.url(URL(string: "https://login.salesforce.com/")!), .url(URL(string: "https://evil.example/")!)]
        reply { m in m.type == "auth.code.get" ? Message("auth.code", ["req": m.string("req")!, "ok": true, "code": "111222", "validFor": 20]) : nil }
        controller.trigger()
        await until("page changed") { self.hud.states.contains(.pageChanged) }
        XCTAssertTrue(typer.typed.isEmpty)
    }

    func testSwitchingBrowserDuringApprovalTypesNothing() async {
        transport.onSend = { [unowned self] m in
            browser.app = .browser(FrontBrowser.match(bundleID: "com.apple.Safari")!)
            broker.handle(Message("auth.code", ["req": m.string("req")!, "ok": true, "code": "333444", "validFor": 20]))
        }
        controller.trigger()
        await until("page changed") { self.hud.states.contains(.pageChanged) }
        XCTAssertTrue(typer.typed.isEmpty)
    }

    func testNeedsAccessibilityBeforeAskingThePhone() async {
        trust.isTrusted = false
        controller.trigger()
        await until("needs accessibility") { self.hud.states.contains(.needsAccessibility) }
        XCTAssertTrue(transport.sent.isEmpty, "no approval is requested that could not be typed")
        controller.model.actions.cancel()
        await until("ended") { !self.controller.isRunning }
    }

    func testNotABrowserAndNoPage() async {
        browser.app = .other(name: "Notes")
        controller.trigger()
        await until("unsupported") { self.hud.states.contains(.unsupportedApp("Notes")) }
        await until("ended") { !self.controller.isRunning }
        browser.app = .browser(chrome)
        browser.urls = [.url(URL(string: "about:blank")!)]
        controller.trigger()
        await until("no page") { self.hud.states.contains(.noPage) }
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testAutomationExplainedOnceThenDeniedMessage() async {
        explained = false
        browser.urls = [.automationDenied]
        controller.trigger()
        await until("explain") { self.hud.states.contains(.explainAutomation(browser: "Chrome")) }
        controller.model.actions.proceed()
        await until("denied note") { self.hud.states.contains(.needsAutomation(browser: "Chrome")) }
        XCTAssertTrue(explained)
        controller.model.actions.cancel()
        await until("ended") { !self.controller.isRunning }
    }

    func testNoMatchThenLinkWithLookalikeWarning() async {
        browser.urls = [.url(URL(string: "https://login.paypa1.com/")!)]
        var asked = 0
        reply { [unowned self] m in
            switch m.type {
            case "auth.list.get":
                return Message("auth.list", ["req": m.string("req")!, "items": [["id": "p1", "issuer": "PayPal", "account": "me@x.com", "domains": ["paypal.com"], "digits": 6]]])
            case "auth.code.get":
                asked += 1
                if m.string("entryId") == "p1" { return Message("auth.code", ["req": m.string("req")!, "ok": true, "code": "909090", "validFor": 20]) }
                _ = self
                return Message("auth.code", ["req": m.string("req")!, "ok": false, "error": "no_match"])
            default: return nil
            }
        }
        controller.trigger()
        await until("no match") { self.hud.states.contains(.noMatch(domain: "paypa1.com")) }
        controller.model.actions.startLink()
        await until("picker") { if case .link = self.hud.states.last { return true }; return false }
        controller.model.actions.pick("p1")
        await until("lookalike warning") { if case .linkConfirm(_, _, let l) = self.hud.states.last { return l.resembles == "paypal.com" }; return false }
        XCTAssertFalse(transport.sent.contains { $0.type == "auth.domain.set" }, "nothing is linked before the user confirms")
        controller.model.actions.confirmLookalike()
        await until("filled") { self.hud.states.contains(.filled(domain: "paypa1.com")) }
        XCTAssertEqual(typer.typed, ["909090"])
        let set = transport.sent.first { $0.type == "auth.domain.set" }
        XCTAssertEqual(set?.string("domain"), "paypa1.com")
        XCTAssertEqual(set?.string("entryId"), "p1")
        XCTAssertEqual(asked, 2)
    }

    func testAmbiguousPicker() async {
        reply { m in
            guard m.type == "auth.code.get" else { return nil }
            if m.string("entryId") == "b" { return Message("auth.code", ["req": m.string("req")!, "ok": true, "code": "777777", "validFor": 9]) }
            return Message("auth.code", ["req": m.string("req")!, "ok": false, "error": "ambiguous",
                                         "choices": [["id": "a", "issuer": "Okta", "account": "one"], ["id": "b", "issuer": "Okta", "account": "two"]]])
        }
        controller.trigger()
        await until("picker") { if case .ambiguous = self.hud.states.last { return true }; return false }
        controller.model.actions.pick("b")
        await until("filled") { self.hud.states.contains(.filled(domain: "salesforce.com")) }
        XCTAssertEqual(typer.typed, ["777777"])
    }

    func testCancelWhileWaitingForThePhone() async {
        controller.trigger()
        await until("waiting") { self.hud.states.contains(.waiting(domain: "salesforce.com")) }
        controller.trigger()                       // the shortcut again cancels
        await until("ended") { !self.controller.isRunning }
        XCTAssertTrue(typer.typed.isEmpty)
        XCTAssertGreaterThan(hud.dismissals, 0)
    }

    func testOfflineIsReported() async {
        broker.setConnected(false)
        controller.trigger()
        await until("offline") { self.hud.states.contains(.offline) }
        XCTAssertTrue(transport.sent.isEmpty)
    }
}

@MainActor
final class AuthenticatorSupportTests: XCTestCase {
    func testSiteRules() {
        XCTAssertEqual(AuthSite(url: URL(string: "https://Login.Salesforce.com/x?y=1")!)?.domain, "salesforce.com")
        XCTAssertEqual(AuthSite(url: URL(string: "https://accounts.google.co.in/")!)?.domain, "google.co.in")
        XCTAssertNil(AuthSite(url: URL(string: "http://login.example.com/")!), "plain http is refused")
        XCTAssertNotNil(AuthSite(url: URL(string: "http://localhost:3000/")!))
        XCTAssertNil(AuthSite(url: URL(string: "file:///etc/hosts")!))
        XCTAssertNil(AuthSite(url: URL(string: "about:blank")!))
    }

    func testShortcutDisplayAndDefaults() {
        XCTAssertEqual(AuthShortcutKey.standard.display, "\u{2303}\u{2325}C")
        var p = MacPrefs()
        XCTAssertTrue(p.authShortcutEnabled)
        p.authAutofillSites = ["okta.com"]
        p.authShortcut = AuthShortcutKey(keyCode: 9, modifiers: 256, label: "V")
        let d = UserDefaults(suiteName: "mydroid.auth.\(UUID().uuidString)")!
        p.save(d)
        let back = MacPrefs.load(d)
        XCTAssertEqual(back.authAutofillSites, ["okta.com"])
        XCTAssertEqual(back.authShortcut.display, "\u{2318}V")
        // An older saved preference without the new keys still loads with the defaults.
        d.set(try! JSONSerialization.data(withJSONObject: ["codeCardMinutes": 5]), forKey: MacPrefs.key)
        XCTAssertEqual(MacPrefs.load(d).authShortcut, .standard)
    }

    func testSupportedBrowsers() {
        for id in ["com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser"] {
            XCTAssertNotNil(FrontBrowser.match(bundleID: id), id)
        }
        XCTAssertNil(FrontBrowser.match(bundleID: "com.apple.Notes"))
        XCTAssertTrue(FrontBrowser.match(bundleID: "com.apple.Safari")!.script.contains("current tab"))
        XCTAssertTrue(FrontBrowser.match(bundleID: "com.google.Chrome")!.script.contains("active tab"))
    }

    func testExtensionInstallerWorksOnAnIsolatedHome() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mydroid-ext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let host = home.appendingPathComponent("Mydroid.app/Contents/MacOS/mydroid-nmhost")
        try FileManager.default.createDirectory(at: host.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: host.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        let inst = ExtensionInstaller(home: home, hostPath: host.path, extensionFolder: nil, applicationDirectories: [home.appendingPathComponent("Applications")])
        XCTAssertTrue(inst.helperAvailable)
        XCTAssertEqual(inst.rows.map(\.browser), [.chrome, .edge, .brave, .arc])
        XCTAssertTrue(inst.rows.allSatisfy { $0.state == .notInstalled && !$0.present })
        inst.install(.arc)
        XCTAssertEqual(inst.rows.first { $0.browser == .arc }?.state, .installed)
        XCTAssertTrue(inst.rows.first { $0.browser == .arc }?.present ?? false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Application Support/Arc/User Data/NativeMessagingHosts/com.mydroid.otp.json").path))
        XCTAssertEqual(inst.rows.first { $0.browser == .chrome }?.state, .notInstalled)
        inst.remove(.arc)
        XCTAssertEqual(inst.rows.first { $0.browser == .arc }?.state, .notInstalled)
    }

    func testAutofillSitesFlowThroughTheSocketServiceIntoPreferences() async {
        let m = AppModel(fixture: HubState())
        _ = await OTPBridge(broker: m.hub.auth, host: m.otpService).handle(["op": "autofill", "host": "login.okta.com", "on": true])
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(m.prefs.authAutofillSites, ["okta.com"])
        XCTAssertTrue(m.otpService.autofillAllowed(domain: "okta.com"))
        m.prefs.authAutofillSites = []
        XCTAssertFalse(m.otpService.autofillAllowed(domain: "okta.com"))
    }
}

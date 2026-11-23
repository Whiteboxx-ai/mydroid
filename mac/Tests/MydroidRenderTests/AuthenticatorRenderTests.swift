import XCTest
import SwiftUI
import AppKit
@testable import Mydroid
@testable import MydroidCore
@testable import MydroidNM

/// Off-screen renders of Settings > Authenticator and the shortcut HUD (light and dark). Only runs when MYDROID_RENDER_DIR is set.
@MainActor
final class AuthenticatorRenderTests: XCTestCase {
    private var dir: String? { ProcessInfo.processInfo.environment["MYDROID_RENDER_DIR"] }

    private func state(link: LinkState = .connected) -> HubState {
        var st = HubState()
        st.link = link
        st.phone = PhoneInfo(name: "Pixel 9", model: "Pixel 9", battery: 78, charging: false, network: .wifi)
        return st
    }

    private func write<V: View>(_ name: String, _ scheme: ColorScheme, size: CGSize, _ content: V) throws {
        guard let dir else { throw XCTSkip("MYDROID_RENDER_DIR not set") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let host = NSHostingView(rootView: content)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        win.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<6 { host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("no bitmap for \(name)") }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return XCTFail("png failed for \(name)") }
        try png.write(to: URL(fileURLWithPath: "\(dir)/\(name)-\(scheme == .dark ? "dark" : "light").png"))
    }

    func testSettingsAuthenticator() throws {
        var prefs = MacPrefs()
        prefs.authAutofillSites = ["okta.com", "salesforce.com"]
        let m = AppModel(fixture: state(), prefs: prefs)
        m.extensionInstaller.install(.chrome)      // an isolated fixture home, never the real profile
        m.extensionInstaller.install(.arc)
        let empty = AppModel(fixture: state(link: .searching))
        for s in [ColorScheme.light, .dark] {
            try write("auth-settings", s, size: CGSize(width: 740, height: 900), SettingsView(initial: .authenticator, height: 900).environment(m))
            try write("auth-settings-offline", s, size: CGSize(width: 740, height: 900), SettingsView(initial: .authenticator, height: 900).environment(empty))
        }
    }

    private func hudCard(_ state: AuthHUDState, _ scheme: ColorScheme) -> some View {
        let model = AuthHUDModel(state: state)
        return ZStack {
            LinearGradient(colors: scheme == .dark ? [Color(white: 0.18), Color(red: 0.12, green: 0.16, blue: 0.24)]
                                                   : [Color(white: 0.93), Color(red: 0.80, green: 0.88, blue: 0.97)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            AuthHUDView(model: model).padding(.vertical, 10)
        }
        .frame(width: AuthHUDView.width + 80)
        .environment(\.colorScheme, scheme)
    }

    func testHUDStates() throws {
        let entries = [AuthEntry(id: "1", issuer: "Salesforce", account: "me@work.com", domains: ["salesforce.com"]),
                       AuthEntry(id: "2", issuer: "GitHub", account: "octo-cat", domains: ["github.com"]),
                       AuthEntry(id: "3", issuer: "Google", account: "me@gmail.com", domains: ["google.com"])]
        let lookalike = LookalikeDetector.assess(host: "paypa1.com", known: [KnownSite(issuer: "PayPal", domains: ["paypal.com"])])!
        let cases: [(String, AuthHUDState)] = [
            ("explain", .explainAutomation(browser: "Chrome")),
            ("waiting", .waiting(domain: "salesforce.com")),
            ("filled", .filled(domain: "salesforce.com")),
            ("denied", .denied),
            ("timeout", .timedOut),
            ("locked", .locked),
            ("offline", .offline),
            ("nomatch", .noMatch(domain: "acme-portal.io")),
            ("link-picker", .link(domain: "acme-portal.io", entries: entries)),
            ("link-confirm", .linkConfirm(domain: "paypa1.com", entry: AuthEntry(id: "p", issuer: "PayPal", account: "me@x.com"), lookalike: lookalike)),
            ("ambiguous", .ambiguous(domain: "okta.com", choices: [AuthChoice(id: "a", issuer: "Okta", account: "one@work.com"), AuthChoice(id: "b", issuer: "Okta", account: "two@work.com")])),
            ("needs-accessibility", .needsAccessibility),
            ("needs-automation", .needsAutomation(browser: "Safari")),
            ("unsupported", .unsupportedApp("Notes")),
            ("page-changed", .pageChanged),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (name, st) in cases {
                try write("hud-\(name)", scheme, size: CGSize(width: AuthHUDView.width + 80, height: 240), hudCard(st, scheme))
            }
        }
    }

    func testPresentationTextIsCalmAndNeverLeaksADomainlessCode() {
        for st in [AuthHUDState.waiting(domain: "x.com"), .filled(domain: "x.com"), .denied, .timedOut] {
            let p = st.presentation
            XCTAssertFalse(p.title.isEmpty)
            XCTAssertFalse(p.title.contains("!"))
        }
        XCTAssertTrue(AuthHUDState.filled(domain: "x.com").isTerminal)
        XCTAssertFalse(AuthHUDState.waiting(domain: "x.com").isTerminal)
    }
}

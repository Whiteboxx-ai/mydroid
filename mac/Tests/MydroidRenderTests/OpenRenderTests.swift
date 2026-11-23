import XCTest
import SwiftUI
import AppKit
@testable import Mydroid
@testable import MydroidCore

/// Off-screen renders of "open notifications from the Mac" (PROTOCOL.md 13). Only run with MYDROID_RENDER_DIR set.
@MainActor
final class OpenRenderTests: XCTestCase {
    private var dir: String? { ProcessInfo.processInfo.environment["MYDROID_RENDER_DIR"] }
    private func now(_ ago: TimeInterval) -> Date { Date().addingTimeInterval(-ago) }

    /// SwiftUI's `.contextMenu` is an AppKit popup and can't be drawn off-screen, so this draws the same entries
    /// (`NotifUIState.menu(for:)`, which the real menu is built from) the way a macOS menu looks.
    private struct MenuMock: View {
        var groups: [[NotifMenuEntry]]
        var highlighted: NotifMenuEntry.Kind?
        @Environment(\.colorScheme) private var scheme
        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(groups.enumerated()), id: \.offset) { i, g in
                    if i > 0 { Divider().padding(.vertical, 3).padding(.horizontal, 4) }
                    ForEach(g) { e in
                        let on = e.kind == highlighted
                        HStack(spacing: 8) {
                            Image(systemName: e.symbol).font(.system(size: 12)).frame(width: 16)
                            Text(e.title).font(.system(size: 13))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3.5)
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .background(on ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }
            }
            .padding(6).frame(width: 196)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(scheme == .dark ? Color(white: 0.24) : Color(white: 0.985)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
        }
    }

    private func render<V: View>(_ name: String, _ scheme: ColorScheme, width: CGFloat, _ content: V) throws {
        guard let dir else { throw XCTSkip("MYDROID_RENDER_DIR not set") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let view = content.environment(\.colorScheme, scheme).frame(width: width)
            .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.96))
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            return XCTFail("render failed for \(name)")
        }
        try png.write(to: URL(fileURLWithPath: "\(dir)/\(name)-\(scheme == .dark ? "dark" : "light").png"))
    }

    private func renderWindow<V: View>(_ name: String, _ scheme: ColorScheme, size: CGSize, _ content: V) throws {
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

    private func gmail() -> PhoneNotification {
        PhoneNotification(key: "g", pkg: "com.google.android.gm", app: "Gmail", title: "Acme Billing",
                          text: "Your invoice is ready \u{00B7} tap to open", when: now(2400))
    }

    private func whatsapp() -> PhoneNotification {
        PhoneNotification(key: "w", pkg: "com.whatsapp", app: "WhatsApp", title: "Maya Tan", text: "lunch tomorrow?", when: now(120),
                          canReply: true, category: .message,
                          conversation: Conversation(title: "Maya Tan", messages: [ConversationMessage(sender: "Maya Tan", text: "lunch tomorrow?", when: now(120))]),
                          person: NotificationPerson(name: "Maya Tan", phone: "+919876543210"))
    }

    private func model() -> AppModel {
        var k = KnownApps()
        for (i, (pkg, name)) in [("com.whatsapp", "WhatsApp"), ("com.google.android.gm", "Gmail"), ("org.telegram.messenger", "Telegram"),
                                  ("com.twitter.android", "X"), ("com.spotify.music", "Spotify"), ("com.slack", "Slack"),
                                  ("in.amazon.mShop.android.shopping", "Amazon")].enumerated() {
            k.note(PhoneNotification(key: "k\(i)", pkg: pkg, app: name))
        }
        var prefs = MacPrefs()
        prefs.setClickBehavior(.phone, for: "com.whatsapp")
        prefs.setClickBehavior(.web, for: "com.twitter.android")
        prefs.setClickBehavior(.nothing, for: "com.slack")
        var st = HubState()
        st.link = .connected
        st.phone = PhoneInfo(name: "Pixel 9")
        st.settings.mutedApps = ["com.spotify.music"]
        return AppModel(fixture: st, knownApps: k, prefs: prefs)
    }

    func testRenderMenusAndSettings() throws {
        try XCTSkipIf(dir == nil, "MYDROID_RENDER_DIR not set")
        let m = model()
        for scheme in [ColorScheme.light, .dark] {
            let u = m.ui
            // A popover row with the context menu open on it.
            var list = NotificationList()
            list.post(whatsapp()); list.post(gmail())
            try render("open-context-menu-row", scheme, width: 372, ZStack(alignment: .topLeading) {
                NotificationsPanel(list: list, scrollable: false).padding(12).environment(u)
                MenuMock(groups: u.menu(for: gmail()), highlighted: .openOnWeb).padding(.leading, 120).padding(.top, 150)
            }.frame(height: 340))
            // The menu for a message (WhatsApp has a web chat too), and for an app with no web page.
            let slack = PhoneNotification(key: "s", pkg: "com.slack", app: "Slack", title: "#design-review", text: "Sam: uploaded v3")
            try render("open-context-menu-variants", scheme, width: 440, HStack(alignment: .top, spacing: 16) {
                MenuMock(groups: u.menu(for: whatsapp()), highlighted: nil)
                MenuMock(groups: u.menu(for: slack), highlighted: .search)
            }.padding(16))
            // A banner with its menu.
            try render("open-banner-with-menu", scheme, width: 400, VStack(alignment: .leading, spacing: 0) {
                BannerView(item: BannerItem(whatsapp()), onClose: {}, onDismiss: {}).environment(u)
                MenuMock(groups: u.menu(for: whatsapp()), highlighted: .openOnPhone).padding(.leading, 150).padding(.top, -4)
            }.padding(.vertical, 4))
            try render("open-banner-app", scheme, width: 400, BannerView(item: BannerItem(gmail()), onClose: {}, onDismiss: {}).environment(u).padding(.vertical, 4))
            // Settings > Notifications with "When clicked".
            try renderWindow("open-settings-notifications", scheme, size: CGSize(width: 740, height: 1100),
                             SettingsView(initial: .notifications, height: 1100).environment(m))
        }
    }
}

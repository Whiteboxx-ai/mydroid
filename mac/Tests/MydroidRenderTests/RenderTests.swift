import XCTest
import SwiftUI
import AppKit
@testable import Mydroid
@testable import MydroidCore

/// Renders the notification UI with fixture data into PNGs. Only runs when MYDROID_RENDER_DIR is set,
/// so it never touches the screen and `swift test` stays quiet.
@MainActor
final class RenderTests: XCTestCase {
    private var dir: String? { ProcessInfo.processInfo.environment["MYDROID_RENDER_DIR"] }

    private func now(_ ago: TimeInterval) -> Date { Date().addingTimeInterval(-ago) }

    private func avatar(_ hue: CGFloat, _ symbol: String) -> Data {
        let img = NSImage(size: NSSize(width: 96, height: 96), flipped: false) { r in
            NSColor(hue: hue, saturation: 0.5, brightness: 0.85, alpha: 1).setFill(); r.fill(); return true
        }
        return NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }

    private func fixtures() -> NotificationList {
        var l = NotificationList()
        l.post(PhoneNotification(key: "otp", pkg: "com.google.android.apps.messaging", app: "Messages", title: "HDFCBK",
                                 text: "482196 is your OTP for txn of Rs 2,400. Do not share.", when: now(95),
                                 category: .message, otp: OneTimeCode(code: "482196", source: "HDFC Bank")))
        l.post(PhoneNotification(key: "grp", pkg: "com.whatsapp", app: "WhatsApp", title: "Goa trip", text: "Dev: booking the villa now",
                                 when: now(60), canReply: true, actions: [NotificationAction(index: 0, title: "Mark as read")],
                                 category: .message,
                                 conversation: Conversation(title: "Goa trip", isGroup: true, messages: [
                                    ConversationMessage(sender: "Maya", text: "Are we still doing the 14th?", when: now(500)),
                                    ConversationMessage(sender: "Maya", text: "Flights are cheaper on Friday", when: now(480)),
                                    ConversationMessage(sender: "", text: "Yes, 14th works for me", when: now(300)),
                                    ConversationMessage(sender: "Dev", text: "Same. Found a villa with a pool", when: now(120)),
                                    ConversationMessage(sender: "Dev", text: "booking the villa now", when: now(60)),
                                 ], avatar: nil)))
        l.post(PhoneNotification(key: "dm", pkg: "org.telegram.messenger", app: "Telegram", title: "Maya Tan", text: "lunch tomorrow?",
                                 when: now(1500), canReply: true, category: .message,
                                 conversation: Conversation(title: "Maya Tan", isGroup: false, messages: [
                                    ConversationMessage(sender: "Maya Tan", text: "are you free this week?", when: now(1800)),
                                    ConversationMessage(sender: "", text: "thursday maybe", when: now(1700)),
                                    ConversationMessage(sender: "Maya Tan", text: "lunch tomorrow?", when: now(1500)),
                                 ], avatar: avatar(0.55, "person"))))
        for (i, (t, x)) in [("Your invoice is ready", "Acme Billing"), ("Standup moved to 11:30", "Priya Nair"), ("Weekly digest: 14 new issues", "GitHub")].enumerated() {
            l.post(PhoneNotification(key: "gm\(i)", pkg: "com.google.android.gm", app: "Gmail", title: t, text: x + " \u{00B7} tap to open",
                                     when: now(Double(2400 + i * 900)), canReply: i == 1))
        }
        l.post(PhoneNotification(key: "old", pkg: "com.slack", app: "com.slack", title: "#design-review", text: "Sam: uploaded v3 of the onboarding flow", when: now(4000)))
        return l
    }

    private func ui() -> NotifUIState {
        let u = NotifUIState(); u.copiedKey = nil; return u
    }

    private func render<V: View>(_ name: String, _ scheme: ColorScheme, width: CGFloat, _ content: V) throws {
        guard let dir else { throw XCTSkip("MYDROID_RENDER_DIR not set") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let bg = scheme == .dark ? Color(white: 0.16) : Color(white: 0.96)
        let view = content
            .environment(\.colorScheme, scheme)
            .frame(width: width)
            .background(bg)
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            return XCTFail("render failed for \(name)")
        }
        try png.write(to: URL(fileURLWithPath: "\(dir)/\(name)-\(scheme == .dark ? "dark" : "light").png"))
    }

    private func popover(_ list: NotificationList, ui u: NotifUIState, expanded: Set<String> = [], stacks: Set<String> = []) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(Color.brand).frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pixel 8").font(.system(size: 14.5, weight: .semibold))
                    Text("Connected over Wi\u{2011}Fi").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.horizontal, 14).padding(.vertical, 12)
            VStack(spacing: 12) {
                CodeCardsSection(list: list)
                NotificationsPanel(list: list, scrollable: false, initiallyExpanded: expanded, initiallyOpenStacks: stacks)
            }.padding(.horizontal, 12).padding(.bottom, 12)
        }
        .environment(u)
    }

    func testRenderAll() throws {
        try XCTSkipIf(dir == nil, "MYDROID_RENDER_DIR not set")
        let all = fixtures()
        for scheme in [ColorScheme.light, .dark] {
            let u = ui()
            try render("popover-otp-and-messages", scheme, width: 372, popover(all, ui: u))
            u.copiedKey = "otp"
            try render("popover-otp-copied", scheme, width: 372, popover(all, ui: u))
            u.copiedKey = nil
            try render("popover-group-expanded", scheme, width: 372, popover(all, ui: u, expanded: ["grp"]))
            try render("popover-dm-expanded", scheme, width: 372, popover(all, ui: u, expanded: ["dm"]))
            try render("popover-stack-open", scheme, width: 372, popover(all, ui: u, expanded: [], stacks: ["com.google.android.gm"]))
            var gmail = NotificationList()
            for n in all.items where n.pkg == "com.google.android.gm" { gmail.post(n) }
            try render("popover-gmail-stack", scheme, width: 372, popover(gmail, ui: u))
            try render("popover-empty", scheme, width: 372, popover(NotificationList(), ui: u))

            func banner(_ name: String, _ n: PhoneNotification, copied: Bool = false) throws {
                try render(name, scheme, width: 384,
                           BannerView(item: BannerItem(n, autoCopied: copied), onClose: {}, onDismiss: {}).environment(u).padding(.vertical, 4))
            }
            let items = Dictionary(uniqueKeysWithValues: all.items.map { ($0.key, $0) })
            try banner("banner-otp", items["otp"]!)
            try banner("banner-otp-autocopied", items["otp"]!, copied: true)
            try banner("banner-message-group", items["grp"]!)
            try banner("banner-message-dm", items["dm"]!)
            try banner("banner-app", items["gm1"]!)
        }
    }

    // MARK: v1.2

    private func fixtureState() -> HubState {
        var st = HubState()
        st.link = .connected
        st.phone = PhoneInfo(name: "Pixel 9", model: "Pixel 9", battery: 18, charging: false, network: .wifi, lowPowerMode: true)
        st.settings.mutedApps = ["com.slack", "com.instagram.android"]
        st.settings.pauseBelowBattery = 20
        st.notifications = fixtures()
        st.media = MediaState(pkg: "com.spotify.music", app: "Spotify", title: "Midnight City", artist: "M83", album: "Hurry Up",
                              art: avatar(0.08, "music.note"), playing: true, position: 83_000, duration: 244_000,
                              ts: Date().addingTimeInterval(-2), canSeek: true)
        return st
    }

    private func fixtureModel(_ st: HubState? = nil, bluetooth: BluetoothStatus = .on) -> AppModel {
        var k = KnownApps()
        for (i, (pkg, name)) in [("com.whatsapp", "WhatsApp"), ("com.google.android.gm", "Gmail"), ("org.telegram.messenger", "Telegram"),
                                  ("com.slack", "Slack"), ("com.instagram.android", "Instagram"), ("com.spotify.music", "Spotify"),
                                  ("com.google.android.apps.messaging", "Messages")].enumerated() {
            k.note(PhoneNotification(key: "k\(i)", pkg: pkg, app: name, icon: i % 2 == 0 ? avatar(CGFloat(i) / 8, "x") : nil))
        }
        var prefs = MacPrefs()
        prefs.quietHours = QuietHours(enabled: true, from: 22 * 60, to: 7 * 60)
        prefs.showBatteryInMenuBar = true
        prefs.importToApplePhotos = true
        let m = AppModel(fixture: st ?? fixtureState(), knownApps: k, prefs: prefs)
        m.bluetooth = bluetooth
        m.blePresenceActive = bluetooth == .on
        return m
    }

    /// Hosts a view in an off-screen NSWindow (never shown) so AppKit-backed controls (List, Form, Picker) draw.
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

    func testRenderSettingsTabs() throws {
        try XCTSkipIf(dir == nil, "MYDROID_RENDER_DIR not set")
        let model = fixtureModel()
        for scheme in [ColorScheme.light, .dark] {
            for tab in SettingsTab.allCases {
                try renderWindow("settings-\(tab.rawValue)", scheme, size: CGSize(width: 740, height: 560),
                                 SettingsView(initial: tab).environment(model))
            }
        }
        // The app list sits at the bottom of a long tab; render it tall so it can be seen.
        try renderWindow("settings-notifications-tall", .light, size: CGSize(width: 740, height: 960), SettingsView(initial: .notifications, height: 960).environment(model))
        // Bluetooth off, phone tab.
        let off = fixtureModel(bluetooth: .off)
        try renderWindow("settings-phone-bluetooth-off", .light, size: CGSize(width: 740, height: 560), SettingsView(initial: .phone).environment(off))
    }

    func testRenderPopoverNowPlayingAndBanners() throws {
        try XCTSkipIf(dir == nil, "MYDROID_RENDER_DIR not set")
        let model = fixtureModel(bluetooth: .off)
        var noNotifs = model.state
        noNotifs.notifications = NotificationList()
        let quiet = fixtureModel(noNotifs)
        for scheme in [ColorScheme.light, .dark] {
            let u = ui()
            func pop(_ m: AppModel, list: NotificationList) -> some View {
                VStack(spacing: 0) {
                    HeaderView()
                    VStack(spacing: 12) {
                        RecoveryView()
                        NowPlayingSection()
                        NotificationsPanel(list: list, scrollable: false)
                    }.padding(.horizontal, 12).padding(.bottom, 12)
                }.environment(m).environment(u)
            }
            try render("popover-now-playing", scheme, width: 372, pop(model, list: model.state.notifications))
            try render("popover-now-playing-paused", scheme, width: 372, pop(quiet, list: NotificationList()))

            func banner(_ name: String, _ item: BannerItem) throws {
                try render(name, scheme, width: 384, BannerView(item: item, onClose: {}, onDismiss: {}).environment(u).padding(.vertical, 4))
            }
            let link = PhoneNotification(key: "l", pkg: "mydroid.link", app: "Link", title: "Pixel 9", text: "")
            try banner("banner-link", BannerItem(link, kind: .link(URL(string: "https://www.example.com/articles/2025/a-long-path-to-read-later?utm=1")!, from: "Pixel 9")))
            let bat = PhoneNotification(key: "b", pkg: "mydroid.battery", app: "Battery", title: "", text: "")
            try banner("banner-low-battery", BannerItem(bat, kind: .lowBattery(title: "Pixel 9 battery at 18%", detail: "Battery saver is on")))
        }
    }
}

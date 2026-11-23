import XCTest
import SwiftUI
import AppKit
@testable import Mydroid
@testable import MydroidCore

/// Off-screen renders of the Settings panes that have no render of their own (General, Notifications, Photos, Clipboard, Media, Phone),
/// connected and offline, light and dark. Only runs when MYDROID_RENDER_DIR is set. Nothing is shown on screen.
@MainActor
final class SettingsPanesRenderTests: XCTestCase {
    private var dir: String? { ProcessInfo.processInfo.environment["MYDROID_RENDER_DIR"] }

    private func model(link: LinkState = .connected) -> AppModel {
        var st = HubState()
        st.link = link
        st.phone = PhoneInfo(name: "Pixel 9", model: "Pixel 9", battery: 78, charging: false, network: .wifi)
        if link == .searching { st.lastSeen = Date().addingTimeInterval(-240) }
        return AppModel(fixture: st)
    }

    private func render<V: View>(_ name: String, _ scheme: ColorScheme, size: CGSize, _ content: V) throws {
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

    func testEveryPane() throws {
        try XCTSkipIf(dir == nil, "MYDROID_RENDER_DIR not set")
        let on = model()
        let off = model(link: .searching)
        let tabs: [(String, SettingsTab, CGFloat)] = [
            ("settings-general", .general, 600), ("settings-notifications", .notifications, 700), ("settings-photos", .photos, 620),
            ("settings-clipboard", .clipboard, 300), ("settings-media", .media, 360), ("settings-phone", .phone, 640),
        ]
        for s in [ColorScheme.light, .dark] {
            for (name, tab, h) in tabs {
                try render(name, s, size: CGSize(width: 740, height: h), SettingsView(initial: tab, height: h).environment(on))
            }
            try render("settings-phone-offline", s, size: CGSize(width: 740, height: 640), SettingsView(initial: .phone, height: 640).environment(off))
        }
    }
}

import XCTest
import SwiftUI
import AppKit
@testable import Mydroid
@testable import MydroidCore

/// Off-screen renders of the v1.5 UI: the Accessibility card, the ring panel, Settings > Remote and Settings > Walk-away lock,
/// and the two things the popover gains. Only runs when MYDROID_RENDER_DIR is set. Nothing is shown on screen.
@MainActor
final class RemoteRenderTests: XCTestCase {
    private var dir: String? { ProcessInfo.processInfo.environment["MYDROID_RENDER_DIR"] }

    private func state(link: LinkState = .connected) -> HubState {
        var st = HubState()
        st.link = link
        st.phone = PhoneInfo(name: "Pixel 9", model: "Pixel 9", battery: 78, charging: false, network: .wifi)
        st.bleUUID = "de7db8f7-4754-4ef1-ba50-10b977af2e8d"
        st.phoneBleUUID = "077c9215-b54a-4afb-970e-3efc5edd6c5d"
        return st
    }

    private func model(walkAway: Bool = false, prefs: MacPrefs = MacPrefs(), link: LinkState = .connected) -> AppModel {
        var st = state(link: link)
        st.settings.walkAway = walkAway
        return AppModel(fixture: st, prefs: prefs)
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

    /// A floating panel is a material over whatever is behind it; give it a desktop-ish backdrop so the render reads like the real thing.
    private func onDesktop<V: View>(_ content: V, scheme: ColorScheme) -> some View {
        ZStack {
            LinearGradient(colors: scheme == .dark ? [Color(white: 0.18), Color(red: 0.12, green: 0.16, blue: 0.24)]
                                                   : [Color(white: 0.93), Color(red: 0.80, green: 0.88, blue: 0.97)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            content
        }
    }

    private func both(_ body: (ColorScheme) throws -> Void) rethrows { for s in [ColorScheme.light, .dark] { try body(s) } }

    private func fitted<V: View>(_ v: V) -> CGSize {
        let host = NSHostingView(rootView: v)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    func testAccessibilityCardAndRingPanel() throws {
        try XCTSkipIf(dir == nil, "MYDROID_RENDER_DIR not set")
        let card = AccessibilityCardView(open: {}, notNow: {})
        let ring = RingPanelView(stop: {})
        let cardSize = fitted(card), ringSize = fitted(ring)
        XCTAssertGreaterThan(cardSize.height, 120)
        try both { s in
            try renderWindow("remote-accessibility-card", s, size: CGSize(width: cardSize.width + 40, height: cardSize.height + 40),
                             onDesktop(card, scheme: s))
            try renderWindow("remote-ring-panel", s, size: CGSize(width: ringSize.width + 40, height: ringSize.height + 40),
                             onDesktop(ring, scheme: s))
        }
    }

    func testPopoverAdditions() throws {
        try XCTSkipIf(dir == nil, "MYDROID_RENDER_DIR not set")
        let presenting = model()
        presenting.remote.setFixture(trusted: true, presenting: "Keynote")
        let ask = model()
        ask.remote.setFixture(trusted: false, cardRequested: true)
        let quiet = model()
        quiet.remote.setFixture(trusted: true)
        // Not connected: the clicker line stays away.
        let away = model(link: .searching)
        away.remote.setFixture(trusted: true, presenting: "Keynote")
        try both { s in
            for (name, m) in [("clicker-ready", presenting), ("accessibility", ask), ("nothing-new", quiet)] {
                try renderWindow("popover-\(name)", s, size: CGSize(width: 372, height: 150),
                                 VStack(spacing: 12) { ClickerReadyLine(); RecoveryView() }
                                    .padding(12).frame(width: 372, alignment: .top)
                                    .background(Color(nsColor: .windowBackgroundColor)).environment(m))
            }
            try renderWindow("popover-clicker-hidden-when-disconnected", s, size: CGSize(width: 372, height: 90),
                             VStack(spacing: 12) { ClickerReadyLine() }.padding(12).frame(width: 372, alignment: .top)
                                .background(Color(nsColor: .windowBackgroundColor)).environment(away))
        }
    }

    func testSettingsRemote() throws {
        try XCTSkipIf(dir == nil, "MYDROID_RENDER_DIR not set")
        let needs = model()
        needs.remote.setFixture(trusted: false, keynote: .notAsked)
        let ready = model(prefs: { var p = MacPrefs(); p.laserColor = .green; return p }())
        ready.remote.setFixture(trusted: true, presenting: "Keynote", keynote: .allowed)
        let size = CGSize(width: 740, height: 700)
        try both { s in
            try renderWindow("settings-remote-needs-permission", s, size: size, SettingsView(initial: .remote, height: 700).environment(needs))
            try renderWindow("settings-remote-allowed", s, size: size, SettingsView(initial: .remote, height: 700).environment(ready))
        }
    }

    func testSettingsWalkAway() throws {
        try XCTSkipIf(dir == nil, "MYDROID_RENDER_DIR not set")
        let off = model()
        // On, first time: the one-time note about Bluetooth, and a strong signal.
        let first = model(walkAway: true)
        first.remote.setFixture(trusted: true)
        first.walkAway.setFixture(active: true, signal: .strong, rssi: -58)
        // On, set up, a medium signal at the Far setting.
        let tuned = model(walkAway: true, prefs: { var p = MacPrefs(); p.walkAwayNoteSeen = true; p.walkAwaySensitivity = .far; return p }())
        tuned.remote.setFixture(trusted: true)
        tuned.walkAway.setFixture(active: true, signal: .medium, rssi: -77)
        // On, with every warning: weak signal, Bluetooth off, no Accessibility, phone not connected.
        let warn = model(walkAway: true, prefs: { var p = MacPrefs(); p.walkAwayNoteSeen = true; return p }(), link: .searching)
        warn.remote.setFixture(trusted: false)
        warn.walkAway.setFixture(active: true, signal: .none, rssi: nil, bluetooth: .off)
        let weak = model(walkAway: true, prefs: { var p = MacPrefs(); p.walkAwayNoteSeen = true; return p }())
        weak.remote.setFixture(trusted: true)
        weak.walkAway.setFixture(active: true, signal: .weak, rssi: -86)
        let size = CGSize(width: 740, height: 700)
        try both { s in
            try renderWindow("settings-walkaway-off", s, size: size, SettingsView(initial: .walkAway, height: 700).environment(off))
            try renderWindow("settings-walkaway-first-time", s, size: size, SettingsView(initial: .walkAway, height: 700).environment(first))
            try renderWindow("settings-walkaway-tuned", s, size: size, SettingsView(initial: .walkAway, height: 700).environment(tuned))
            try renderWindow("settings-walkaway-weak", s, size: size, SettingsView(initial: .walkAway, height: 700).environment(weak))
            try renderWindow("settings-walkaway-warnings", s, size: size, SettingsView(initial: .walkAway, height: 700).environment(warn))
        }
    }

    func testLaserOverlayWindowIsClickThroughAndEverywhere() throws {
        let overlay = LaserOverlay()
        let w = overlay.builtWindow                       // built, never ordered front: nothing appears on screen
        XCTAssertTrue(w.ignoresMouseEvents, "clicks go straight through")
        XCTAssertFalse(w.canBecomeKey); XCTAssertFalse(w.canBecomeMain)
        XCTAssertFalse(w.isOpaque)
        XCTAssertEqual(w.backgroundColor, .clear)
        XCTAssertTrue(w.collectionBehavior.contains(.canJoinAllSpaces), "on every Space")
        XCTAssertTrue(w.collectionBehavior.contains(.fullScreenAuxiliary), "over full-screen apps")
        XCTAssertGreaterThanOrEqual(w.level.rawValue, Int(CGShieldingWindowLevel()), "above full-screen slideshows")
        XCTAssertTrue(w.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(w.isVisible)
        // It covers the main display.
        if let main = NSScreen.screens.first { XCTAssertEqual(w.frame.size, main.frame.size) }
    }

    func testRenderLaserGlow() throws {
        try XCTSkipIf(dir == nil, "MYDROID_RENDER_DIR not set")
        let dir = try XCTUnwrap(self.dir)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for color in LaserColor.allCases {
            let overlay = LaserOverlay()
            overlay.color = color.nsColor
            // A slide-ish backdrop: the glow must read on both a dark and a light slide.
            for (name, backdrop) in [("dark-slide", NSColor(white: 0.12, alpha: 1)), ("light-slide", NSColor(white: 0.97, alpha: 1))] {
                let rep = try XCTUnwrap(overlay.snapshot(at: CGPoint(x: 0.5, y: 0.5), size: CGSize(width: 320, height: 200), backdrop: backdrop))
                let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: "\(dir)/remote-laser-\(color.rawValue)-\(name).png"))
            }
        }
    }

    func testSidebarHasTheNewSections() {
        // The sidebar icons must exist as SF Symbols on this macOS.
        for t in [SettingsTab.remote, .walkAway] {
            XCTAssertNotNil(NSImage(systemSymbolName: t.icon, accessibilityDescription: nil), t.icon)
        }
        for n in ["cursorarrow.click.2", "switch.2", "play.rectangle.fill", "bell.and.waves.left.and.right.fill", "hand.point.up.left"] {
            XCTAssertNotNil(NSImage(systemSymbolName: n, accessibilityDescription: nil), n)
        }
    }
}

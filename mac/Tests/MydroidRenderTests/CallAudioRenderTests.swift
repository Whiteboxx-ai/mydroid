import XCTest
import SwiftUI
import AppKit
@testable import Mydroid
@testable import MydroidCore

/// Off-screen renders of the call-audio UI: the pending card, each setup step and tier result, the call panel in each audio state,
/// and Settings > Calls. Only runs when MYDROID_RENDER_DIR is set. Nothing is shown on screen.
@MainActor
final class CallAudioRenderTests: XCTestCase {
    private var dir: String? { ProcessInfo.processInfo.environment["MYDROID_RENDER_DIR"] }

    private func state(call: CallInfo? = nil) -> HubState {
        var st = HubState()
        st.link = .connected
        st.phone = PhoneInfo(name: "Pixel 9", model: "Pixel 9", battery: 78, charging: false, network: .wifi)
        st.call = call
        return st
    }

    private func model(call: CallInfo? = nil, enabled: Bool = false, tier: CallAudioTier? = nil, dismissed: Bool = false,
                       route: RouteState = .phone, helper: Bool = true, adb: AdbLinkState = .connected) -> AppModel {
        let m = AppModel(fixture: state(call: call))
        m.callAudio.update {
            $0.enabled = enabled; $0.tier = tier; $0.cardDismissed = dismissed
            $0.lastConnected = Date().addingTimeInterval(-8 * 60)
            $0.keepAliveGranted = true
        }
        m.callAudio.helperRunning = helper && enabled
        m.callAudio.adbState = enabled ? adb : .off
        m.callAudio.route = route
        return m
    }

    private func activeCall(muted: Bool = false) -> CallInfo {
        var c = CallInfo(callId: "c1", phase: .active, incoming: true, number: "+1 415 555 0134", name: "Maya Tan", startedAt: Date().addingTimeInterval(-74))
        c.muted = muted
        return c
    }

    // Hosts a view in an off-screen NSWindow (never shown) so AppKit-backed controls (ProgressView, Form, Picker) draw.
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

    private func both(_ body: @MainActor (ColorScheme) throws -> Void) rethrows { for s in [ColorScheme.light, .dark] { try body(s) } }

    // MARK: Popover

    func testPopoverPendingCardAndTalkCheck() throws {
        try XCTSkipIf(dir == nil, "MYDROID_RENDER_DIR not set")
        let pending = model()
        let asking = model(enabled: true, tier: .full)
        asking.callAudio.update { $0.talkCheckPending = true }
        let dismissed = model(dismissed: true)
        try both { s in
            @MainActor func pop(_ m: AppModel) -> some View {
                VStack(spacing: 0) {
                    HeaderView()
                    VStack(spacing: 12) { CallAudioPendingCard(); TalkCheckCard() }.padding(.horizontal, 12).padding(.bottom, 12)
                }
                .frame(width: 372).background(s == .dark ? Color(white: 0.16) : Color(white: 0.96))
                .environment(m).environment(m.ui)
            }
            try renderWindow("callaudio-popover-pending-card", s, size: CGSize(width: 372, height: 190), pop(pending))
            try renderWindow("callaudio-popover-talk-check", s, size: CGSize(width: 372, height: 170), pop(asking))
            XCTAssertFalse(dismissed.callAudio.showsPendingCard)
        }
    }

    // MARK: Setup sheet

    private func sheet(_ m: AppModel, _ p: SetupProgress) -> some View {
        m.callAudio.setup = p
        return CallAudioSetupView().environment(m)
    }

    func testSetupSteps() throws {
        try XCTSkipIf(dir == nil, "MYDROID_RENDER_DIR not set")
        let m = model()
        let size = CallAudioSetupView.size
        try both { s in
            let p = SetupProgress(service: "mydroid-k3m9p2qr", password: "w7x4n2c8h5jt", phoneName: "Pixel 9")
            p.stage = .devOptions
            try renderWindow("callaudio-setup-1-developer-options", s, size: size, sheet(m, p))
            p.stage = .wirelessDebugging
            try renderWindow("callaudio-setup-2-qr-code", s, size: size, sheet(m, p))
            p.stage = .pairing; p.detail = "Checking it\u{2019}s your Pixel 9\u{2026}"
            try renderWindow("callaudio-setup-3-pairing", s, size: size, sheet(m, p))
            p.stage = .checking
            try renderWindow("callaudio-setup-4-checking", s, size: size, sheet(m, p))
            for (name, tier) in [("full", CallAudioTier.full), ("listen", .listen), ("none", .none)] {
                p.stage = .result(tier)
                try renderWindow("callaudio-setup-result-\(name)", s, size: size, sheet(m, p))
            }
            p.stage = .failed(item: 2, message: "Pairing didn\u{2019}t work. Make sure you scanned the code on this screen, then try again.")
            try renderWindow("callaudio-setup-failed", s, size: size, sheet(m, p))
            let slow = SetupProgress(service: "mydroid-k3m9p2qr", password: "w7x4n2c8h5jt", phoneName: "Pixel 9")
            slow.hint = "Nothing yet? Check both are on the same Wi\u{2011}Fi."
            try renderWindow("callaudio-setup-1-with-hint", s, size: size, sheet(m, slow))
        }
        let text = SetupProgress(phoneName: "Pixel 9")
        XCTAssertEqual(text.items.map(\.title), ["Developer options", "Pair with a QR code", "Pairing", "Checking your phone"])
    }

    // MARK: Call panel

    private func panel(_ m: AppModel) -> some View { CallView().environment(m) }

    /// How tall the call panel wants to be for this state (what the real panel is sized to).
    private func panelHeight(_ m: AppModel) -> CGFloat {
        let host = NSHostingView(rootView: panel(m))
        host.layoutSubtreeIfNeeded()
        return ceil(host.fittingSize.height)
    }

    func testCallPanelAudioStates() throws {
        try XCTSkipIf(dir == nil, "MYDROID_RENDER_DIR not set")
        let call = activeCall()
        let off = model(call: call)                                                                   // audio on the phone, no call audio set up
        let phone = model(call: call, enabled: true, tier: .full)                                      // switch on Phone
        let mac = model(call: call, enabled: true, tier: .full, route: .mac)
        mac.callAudio.update { $0.talkConfirmed = nil }
        mac.callAudio.micActive = true; mac.callAudio.meters.rx = 0.62; mac.callAudio.meters.tx = 0.35
        let confirmed = model(call: call, enabled: true, tier: .full, route: .mac)
        confirmed.callAudio.update { $0.talkConfirmed = true }
        confirmed.callAudio.micActive = true; confirmed.callAudio.meters.rx = 0.8; confirmed.callAudio.meters.tx = 0.0
        let listen = model(call: call, enabled: true, tier: .listen, route: .mac)
        listen.callAudio.meters.rx = 0.5
        let none = model(call: call, enabled: true, tier: CallAudioTier.none)
        let switching = model(call: call, enabled: true, tier: .full, route: .switching(to: .mac))
        let denied = model(call: call, enabled: true, tier: .full, route: .mac)
        denied.callAudio.micDenied = true; denied.callAudio.meters.rx = 0.4
        let refused = model(call: call, enabled: true, tier: .full)
        refused.callAudio.routeError = "Couldn\u{2019}t switch to your Mac. Android wouldn\u{2019}t give Mydroid call audio."
        let offline = model(call: call, enabled: true, tier: .full, helper: false, adb: .searching)
        let ringing = model(call: CallInfo(callId: "c2", phase: .ringing, incoming: true, number: "+1 415 555 0134", name: "Maya Tan", startedAt: Date()),
                            enabled: true, tier: .full)
        try both { s in
            try renderWindow("callaudio-panel-ringing", s, size: CGSize(width: 372, height: panelHeight(ringing)), panel(ringing))
            for (name, m) in [("off", off), ("phone", phone), ("mac-experimental", mac), ("mac-confirmed", confirmed), ("listen", listen),
                              ("none", none), ("switching", switching), ("mic-denied", denied), ("refused", refused), ("reconnecting", offline)] {
                try renderWindow("callaudio-panel-\(name)", s, size: CGSize(width: 372, height: panelHeight(m)), panel(m))
            }
        }
        XCTAssertFalse(none.callAudio.showsRouteSwitch, "the none tier shows no switch")
        // The panel grows with the switch, and again with the meter and notes.
        XCTAssertGreaterThan(panelHeight(phone), panelHeight(off))
        XCTAssertGreaterThan(panelHeight(mac), panelHeight(phone))
        XCTAssertLessThan(panelHeight(off), 200)
    }

    func testPopoverOngoingCallRow() throws {
        try XCTSkipIf(dir == nil, "MYDROID_RENDER_DIR not set")
        let call = activeCall()
        let m = model(call: call, enabled: true, tier: .full, route: .mac)
        m.hiddenCalls = ["c1"]
        m.callAudio.micActive = true; m.callAudio.meters.rx = 0.55; m.callAudio.meters.tx = 0.3
        let p = model(call: call, enabled: true, tier: .full)
        p.hiddenCalls = ["c1"]
        try both { s in
            for (name, mm) in [("mac", m), ("phone", p)] {
                try renderWindow("callaudio-popover-call-\(name)", s, size: CGSize(width: 372, height: 190),
                                 VStack(spacing: 12) { OngoingCallRow() }.padding(12).frame(width: 372, alignment: .top)
                                    .background(s == .dark ? Color(white: 0.16) : Color(white: 0.96)).environment(mm))
            }
        }
    }

    // MARK: Settings > Calls

    func testSettingsCalls() throws {
        try XCTSkipIf(dir == nil, "MYDROID_RENDER_DIR not set")
        let off = model()
        let full = model(enabled: true, tier: .full)
        full.callAudio.update { $0.talkCheckPending = true; $0.routeOnAnswer = true }
        let confirmed = model(enabled: true, tier: .full)
        confirmed.callAudio.update { $0.talkConfirmed = true }
        let listen = model(enabled: true, tier: .listen, adb: .unreachable)
        let none = model(tier: CallAudioTier.none)
        let size = CGSize(width: 740, height: 1000)
        try both { s in
            try renderWindow("callaudio-settings-off", s, size: size, SettingsView(initial: .calls, height: 1000).environment(off))
            try renderWindow("callaudio-settings-full", s, size: size, SettingsView(initial: .calls, height: 1000).environment(full))
            try renderWindow("callaudio-settings-full-confirmed", s, size: size, SettingsView(initial: .calls, height: 1000).environment(confirmed))
            try renderWindow("callaudio-settings-listen", s, size: size, SettingsView(initial: .calls, height: 1000).environment(listen))
            try renderWindow("callaudio-settings-none", s, size: size, SettingsView(initial: .calls, height: 1000).environment(none))
        }
    }
}

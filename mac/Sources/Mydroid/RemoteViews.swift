import SwiftUI
import AppKit
import MydroidCore

// MARK: Accessibility card

/// "Allow Mydroid to control this Mac from your phone". Shown in a floating panel when the phone asks, or when input arrives without permission.
/// It closes by itself once macOS says yes (the controller checks on app activation and every 2 s while it is up).
struct AccessibilityCardView: View {
    static let width: CGFloat = 392
    var open: () -> Void
    var notNow: () -> Void
    var reset: () -> Void = {}
    /// Called when the card grows, so its window can grow with it.
    var resized: () -> Void = {}
    @State private var stuck = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(LinearGradient(colors: [.brand, .brand.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                    Image(systemName: "cursorarrow.click.2").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Control this Mac from your phone")
                        .font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text("macOS shows a small box. Choose Open System Settings, switch Mydroid on, then close the box.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Label {
                Text("Privacy & Security \u{203A} Accessibility \u{203A} **Mydroid**")
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            } icon: { Image(systemName: "switch.2").foregroundStyle(Brand.accent) }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Not Now", action: notNow).buttonStyle(.bordered).controlSize(.regular)
                Button("Open Settings", action: open).buttonStyle(.borderedProminent).controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for permission\u{2026}").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
            }
            if stuck {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Already switched on? macOS ties the switch to one exact copy of the app, so a rebuilt or updated Mydroid needs it again.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Reset and ask again", action: reset).controlSize(.small)
                }
                .transition(.opacity)
            }
        }
        .task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            withAnimation { stuck = true }
            try? await Task.sleep(nanoseconds: 400_000_000)
            resized()
        }
        .padding(14)
        .frame(width: Self.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .padding(6)
    }
}

/// The same ask, inside the menu-bar popover (while the card is wanted and permission is still missing).
struct AccessibilityRecoveryCard: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        RecoveryCard(icon: "cursorarrow.click.2", tint: .orange,
                     title: "Allow remote control",
                     message: "Trackpad, keyboard and clicker need Accessibility.") {
            HStack(spacing: 8) {
                Button("Open Settings") { model.remote.openAccessibilitySettings() }.controlSize(.small).buttonStyle(.bordered)
                Button("Reset") { model.remote.resetAccessibilityAndAsk() }.controlSize(.small).buttonStyle(.bordered)
                    .help("Already switched on but still waiting? Clears Mydroid's entry and asks again.")
                Button("Not Now") { model.remote.dismissCard() }.controlSize(.small).buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
    }
}

/// One quiet line while a slideshow is on and the phone is connected.
struct ClickerReadyLine: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if model.state.link == .connected, model.remote.presenting != nil {
            HStack(spacing: 6) {
                Image(systemName: "play.rectangle.fill").font(.system(size: 11)).foregroundStyle(Brand.accent)
                Text("Clicker ready on your phone").font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .transition(.opacity)
        }
    }
}

// MARK: Settings > Remote

struct RemoteSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        let r = model.remote
        Form {
            Section {
                LabeledContent {
                    HStack(spacing: 6) {
                        StatusText(text: r.trusted ? "Allowed" : "Needs permission", color: r.trusted ? .green : .orange)
                        if !r.trusted { Button("Open Settings") { r.openAccessibilitySettings() }.controlSize(.small) }
                    }
                } label: {
                    InfoLabel("Accessibility", icon: "hand.point.up.left",
                              info: "Lets your phone move the pointer, click, type and press media keys. Lock from your phone needs it too. After an update, switch Mydroid off and on again if macOS asks.")
                }
                Toggle("Reverse scroll direction", isOn: $m.prefs.reverseScroll)
            } header: { Text("Trackpad and keyboard") }

            Section {
                LabeledContent("Color") {
                    HStack(spacing: 8) {
                        ForEach(LaserColor.allCases) { c in
                            Button { m.prefs.laserColor = c } label: {
                                Circle().fill(c.color).frame(width: 18, height: 18)
                                    .overlay(Circle().strokeBorder(.primary.opacity(m.prefs.laserColor == c ? 0.9 : 0.15), lineWidth: m.prefs.laserColor == c ? 2 : 0.5))
                                    .padding(2)
                            }
                            .buttonStyle(.plain).help(c.title).accessibilityLabel(c.title)
                        }
                    }
                }
                LabeledContent("Preview") {
                    Button("Show Laser") { r.previewLaser() }.controlSize(.small)
                }
            } header: { Text("Laser pointer") }

            // Only where it applies: Keynote installed, or a slideshow running.
            if r.keynoteAutomation != .notInstalled || r.presenting != nil {
                Section {
                    if r.keynoteAutomation != .notInstalled {
                        LabeledContent {
                            HStack(spacing: 6) {
                                let k = keynoteRow(r.keynoteAutomation)
                                StatusText(text: k.text, color: k.color)
                                if r.keynoteAutomation == .notAsked { Button("Allow") { r.allowKeynoteDetection() }.controlSize(.small) }
                            }
                        } label: {
                            InfoLabel("Keynote", icon: "play.rectangle",
                                      info: "Mydroid notices slideshows in Keynote, PowerPoint, Preview or a full-screen browser tab, and offers the clicker on your phone. Allowing Automation makes Keynote detection exact.")
                        }
                    }
                    if let p = r.presenting {
                        LabeledContent { Text(p).foregroundStyle(.secondary) } label: { Label("Presenting", systemImage: "dot.radiowaves.left.and.right") }
                    }
                } header: { Text("Presenting") }
            }
        }
    }

    private func keynoteRow(_ s: PresentingMonitor.AutomationState) -> (text: String, color: Color) {
        switch s {
        case .notInstalled: return ("Not installed", .gray)
        case .notAsked: return ("Not allowed", .gray)
        case .allowed: return ("Allowed", .green)
        case .denied: return ("Needs permission", .orange)
        }
    }
}

// MARK: Settings > Walk-away lock

struct SignalMeter: View {
    var rssi: Double?
    var threshold: Double
    var level: SignalLevel

    private var tint: Color {
        switch level {
        case .strong: return .green
        case .medium: return .yellow
        case .weak: return .orange
        case .none: return .gray
        }
    }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                if let rssi, level != .none {
                    Capsule().fill(tint.gradient).frame(width: max(8, w * WalkAwayMachine.meterFraction(rssi: rssi)))
                }
                // Where it counts as away.
                Rectangle().fill(Color.primary.opacity(0.55)).frame(width: 2, height: 14)
                    .offset(x: w * WalkAwayMachine.meterFraction(rssi: threshold) - 1)
            }
            .animation(.easeOut(duration: 0.3), value: rssi)
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel("Phone signal \(level.label)")
    }
}

struct WalkAwaySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        let w = model.walkAway
        let on = model.state.settings.walkAway
        Form {
            Section {
                InfoToggle("Lock when I walk away", isOn: Binding(get: { on }, set: { model.setWalkAway($0) }),
                           info: "Locks this Mac a few seconds after your phone is out of range, unless you are using it. Needs Bluetooth on both devices; nothing else goes over it.")
                    .disabled(!model.isPaired)
            } header: { Text("Walk-away lock") } footer: {
                FooterNote("It never unlocks your Mac.", icon: "lock.shield")
            }

            if on {
                Section {
                    Picker("Sensitivity", selection: $m.prefs.walkAwaySensitivity) {
                        ForEach(WalkAwaySensitivity.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Wake display when I return", isOn: $m.prefs.walkAwayWake)
                } header: { Text("Options") } footer: {
                    Text(sensitivityHelp(m.prefs.walkAwaySensitivity))
                }

                Section {
                    LabeledContent {
                        Text(signalText(w)).foregroundStyle(.secondary).monospacedDigit()
                    } label: { Text("Phone signal: \(w.signal.label)") }
                    SignalMeter(rssi: w.rssi, threshold: m.prefs.walkAwaySensitivity.threshold, level: w.signal)
                } header: {
                    HStack(spacing: 5) {
                        Text("Signal")
                        InfoButton("Carry your phone to where you want the Mac to lock. If the bar falls left of the line there, that is where it locks.")
                    }
                }

                if let warn = warnings(w) {
                    Section { ForEach(warn, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange) } }
                }
            }
        }
    }

    private func sensitivityHelp(_ s: WalkAwaySensitivity) -> String {
        switch s {
        case .near: return "Locks a few steps from your desk."
        case .medium: return "Locks when you leave the room."
        case .far: return "Locks only when well out of range."
        }
    }

    private func signalText(_ w: WalkAwayController) -> String {
        guard let r = w.rssi, w.signal != .none else { return w.active ? "Listening\u{2026}" : "" }
        return "\(Int(r.rounded())) dBm"
    }

    private func warnings(_ w: WalkAwayController) -> [String]? {
        var out: [String] = []
        switch w.bluetooth {
        case .off: out.append("Bluetooth is off")
        case .unauthorized: out.append("Allow Bluetooth in Privacy & Security")
        case .unsupported: out.append("This Mac has no Bluetooth")
        default: break
        }
        if model.state.link != .connected { out.append("Your phone isn\u{2019}t connected") }
        if !model.remote.trusted { out.append("Without Accessibility, only the display sleeps") }
        return out.isEmpty ? nil : out
    }
}

import SwiftUI
import AppKit
import MydroidCore

// MARK: Popover cards

/// "Hear calls on your Mac": shown after setup until the user sets it up or says Not now.
struct CallAudioPendingCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.callAudio.showsPendingCard, model.state.link == .connected {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "phone.arrow.down.left").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.brand).frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Call audio").font(.system(size: 12.5, weight: .semibold))
                    Text("Hear calls through your Mac.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Set Up") { model.openCallAudioSetup() }.buttonStyle(.borderedProminent).controlSize(.small)
                        Button("Not Now") { withAnimation(.spring(duration: 0.35)) { model.callAudio.dismissCard() } }
                            .buttonStyle(.bordered).controlSize(.small)
                            .help("You can set it up later in Settings \u{203A} Calls")
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(11)
            .background(Color.brand.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
    }
}

/// Asked once, after the first call heard through the Mac with the microphone on.
struct TalkCheckCard: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if model.callAudio.prefs.talkCheckPending {
            RecoveryCard(icon: "mic.fill", tint: .orange, title: "Did they hear you?",
                         message: "Talking from your Mac is experimental.") {
                HStack(spacing: 8) {
                    Button("Yes") { model.callAudio.answerTalkCheck(heard: true) }.buttonStyle(.borderedProminent).controlSize(.small)
                    Button("No") { model.callAudio.answerTalkCheck(heard: false) }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }
}

// MARK: Route switch and meter (call panel and popover)

/// Phone \u{00B7} Mac, like the iPhone's audio route picker. Shown only when the phone's tier allows it.
struct AudioRouteSwitch: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let c = model.callAudio
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                segment("Phone", symbol: "iphone.gen3", route: .phone)
                segment(c.macLabel, symbol: "desktopcomputer", route: .mac)
            }
            .padding(2)
            .background(Color.primary.opacity(0.08), in: Capsule())
            .opacity(c.routeSwitchUsable || c.route.isSwitching ? 1 : 0.55)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Call audio")
            if !c.helperRunning {
                Text(c.adbState == .connected ? "Getting ready\u{2026}" : "Reconnecting\u{2026}")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let err = c.routeError {
                Text(err).font(.system(size: 11)).foregroundStyle(.orange).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func segment(_ title: String, symbol: String, route: AudioRoute) -> some View {
        let c = model.callAudio
        let selected = c.route.shown == route
        return Button {
            c.requestRoute(route)
        } label: {
            HStack(spacing: 5) {
                if c.route == .switching(to: route) { ProgressView().controlSize(.mini) } else { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 6)
            .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.75))
            .background { if selected { Capsule().fill(Color.brand) } }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!c.routeSwitchUsable)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Two small live level meters (what you hear, what the Mac's microphone sends) and the experimental note.
struct RoutedAudioStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let c = model.callAudio
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                LevelBar(symbol: "speaker.wave.2.fill", level: c.meters.rx, tint: .green)
                if c.micActive {
                    LevelBar(symbol: c.meters.tx == 0 && model.state.call?.muted == true ? "mic.slash.fill" : "mic.fill", level: c.meters.tx, tint: .blue)
                }
            }
            if c.prefs.tier == .listen {
                note("ear", "Listening only. Talk into your phone.", .secondary)
            } else if c.micDenied {
                note("mic.slash", "Listening only. Microphone access is off.", .orange)
            } else if c.micUnavailable {
                note("mic.slash", "Listening only. No microphone found.", .orange)
            } else if c.talkIsExperimental {
                note("mic", "Talk from Mac (experimental)", .orange)
            }
        }
    }

    private func note(_ symbol: String, _ text: String, _ tint: Color) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).labelStyle(.titleAndIcon)
    }
}

struct LevelBar: View {
    var symbol: String
    var level: Float
    var tint: Color
    private let bars = 12

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
            HStack(spacing: 2) {
                ForEach(0..<bars, id: \.self) { i in
                    let on = Float(i) < level * Float(bars)
                    Capsule().fill(on ? tint.opacity(i >= bars - 2 ? 1 : 0.85) : Color.primary.opacity(0.12)).frame(width: 4, height: 10)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(symbol.contains("mic") ? "Microphone level" : "Call volume level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}

// MARK: Setup sheet

/// The guided "Hear calls on your Mac" window: a live checklist that advances by itself.
struct CallAudioSetupView: View {
    @Environment(AppModel.self) private var model
    static let size = CGSize(width: 600, height: 580)

    var body: some View {
        Group {
            if let p = model.callAudio.setup {
                SetupSheet(progress: p)
            } else {
                Color.clear
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(.background)
    }
}

struct SetupSheet: View {
    @Environment(AppModel.self) private var model
    var progress: SetupProgress

    var body: some View {
        let p = progress
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(LinearGradient(colors: [.brand, .brand.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                    Image(systemName: "phone.arrow.down.left").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)
                Text("Call audio").font(.system(size: 22, weight: .bold, design: .rounded))
                Text(subtitle(p)).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.top, 26).padding(.horizontal, 40)

            Group {
                if let tier = p.tier {
                    ResultPanel(tier: tier, phoneName: p.phoneName).transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    HStack(alignment: .top, spacing: 22) {
                        Checklist(progress: p).frame(width: 318)
                        RightPanel(progress: p).frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 28).padding(.top, 22)
                    .transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            VStack(spacing: 10) {
                if p.tier != .some(.none) {
                    Text("Some banking apps won\u{2019}t run with Developer options on. Undo any time in Settings \u{203A} Calls.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                buttons(p)
            }
            .padding(.horizontal, 36).padding(.top, 10).padding(.bottom, 22)
        }
        .animation(.spring(duration: 0.5, bounce: 0.15), value: p.stage)
    }

    private func subtitle(_ p: SetupProgress) -> String {
        switch p.stage {
        case .result(.none): return "What your phone supports"
        case .result: return "Your \(p.phoneName) is ready"
        case .failed: return "Setup stopped"
        default: return "Follow the steps on your phone"
        }
    }

    @ViewBuilder
    private func buttons(_ p: SetupProgress) -> some View {
        HStack(spacing: 10) {
            switch p.stage {
            case .result:
                Button { model.callAudio.finishSetup(); closeWindow() } label: { Text("Done").font(.system(size: 14, weight: .semibold)).frame(width: 180) }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            case .failed:
                Button { model.callAudio.retrySetup() } label: { Text("Try Again").font(.system(size: 14, weight: .semibold)).frame(width: 120) }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                Button("Close") { model.callAudio.cancelSetup(); closeWindow() }.controlSize(.large)
            default:
                Button("Cancel") { model.callAudio.cancelSetup(); closeWindow() }.controlSize(.large)
            }
        }
    }

    private func closeWindow() {
        NSApp.windows.first { $0.title == "Call Audio" }?.close()
    }
}

private struct Checklist: View {
    var progress: SetupProgress
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let items = progress.items
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        StatusGlyph(status: item.status)
                        if item.id < items.count - 1 {
                            Rectangle().fill(item.status == .done ? Color.green.opacity(0.5) : Color.primary.opacity(0.12)).frame(width: 2).frame(maxHeight: .infinity)
                                .padding(.vertical, 3)
                        }
                    }
                    .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.system(size: 14, weight: item.status == .active ? .semibold : .medium))
                            .foregroundStyle(item.status == .pending ? Color.secondary : Color.primary)
                        if !item.detail.isEmpty {
                            Text(item.detail).font(.system(size: 12)).foregroundStyle(item.status == .failed ? Color.red : Color.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.bottom, 16)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.title). \(item.detail). \(statusWord(item.status))")
            }
            if let hint = progress.hint, progress.failure == nil {
                Label(hint, systemImage: "lightbulb").font(.system(size: 11.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusWord(_ s: SetupItemStatus) -> String {
        switch s { case .pending: return "Waiting"; case .active: return "In progress"; case .done: return "Done"; case .failed: return "Failed" }
    }
}

struct StatusGlyph: View {
    var status: SetupItemStatus
    var body: some View {
        ZStack {
            switch status {
            case .pending: Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1.5).frame(width: 20, height: 20)
            case .active:
                Circle().fill(Color.brand.opacity(0.15)).frame(width: 22, height: 22)
                ProgressView().controlSize(.small).scaleEffect(0.7)
            case .done:
                Circle().fill(Color.green).frame(width: 20, height: 20)
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            case .failed:
                Circle().fill(Color.red).frame(width: 20, height: 20)
                Image(systemName: "exclamationmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: 24, height: 24)
    }
}

private struct RightPanel: View {
    @Environment(AppModel.self) private var model
    var progress: SetupProgress

    var body: some View {
        VStack(spacing: 12) {
            if progress.showsCode {
                code
                if progress.stage == .devOptions || progress.stage == .wirelessDebugging {
                    Button { model.hub.fix(.devoptions) } label: { Label("Reopen on Phone", systemImage: "arrow.up.forward.app") }
                        .controlSize(.small).buttonStyle(.bordered)
                }
                if progress.stage == .devOptions {
                    Text("No Developer options? Tap Build number 7 times in About phone.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if progress.stage == .checking {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Checking\u{2026}").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(width: 220, height: 220)
            } else if let message = progress.failure {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 28)).foregroundStyle(.orange)
                    Text(message).font(.system(size: 13)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                .padding(16).frame(maxWidth: .infinity).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private var code: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white).shadow(color: .black.opacity(0.12), radius: 14, y: 5)
                if let img = QRCode.image(for: progress.qrPayload) {
                    Image(nsImage: img).interpolation(.none).resizable().scaledToFit().padding(14)
                        .accessibilityLabel("Wireless debugging pairing QR code")
                }
            }
            .frame(width: 220, height: 220)
            .opacity(progress.stage == .pairing ? 0.45 : 1)
            .overlay { if progress.stage == .pairing { ProgressView().controlSize(.large) } }
            Text(progress.stage == .pairing ? "Pairing\u{2026}" : "Scan with Pair device with QR code")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
}

private struct ResultPanel: View {
    var tier: CallAudioTier
    var phoneName: String

    var body: some View {
        let tint: Color = tier == .full ? .green : (tier == .listen ? .brand : .orange)
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(0.14)).frame(width: 92, height: 92)
                Image(systemName: TierCopy.symbol(tier)).font(.system(size: 52)).foregroundStyle(tint).symbolRenderingMode(.hierarchical)
            }
            .padding(.top, 18)
            Text(TierCopy.title(tier)).font(.system(size: 20, weight: .bold, design: .rounded))
            Text(TierCopy.detail(tier)).font(.system(size: 13.5)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 420)
            if tier == .none {
                Text("Wireless debugging is off again.")
                    .font(.system(size: 12)).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
        }
        .padding(.horizontal, 40)
    }
}

// MARK: Settings > Calls

struct CallSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmOff = false
    @State private var outputs: [AudioDevice] = []
    @State private var inputs: [AudioDevice] = []

    var body: some View {
        let c = model.callAudio
        Form {
            Section {
                Toggle("Show incoming calls", isOn: Binding(get: { model.state.settings.calls }, set: { model.setSetting(\.calls, $0) }))
            } header: { Text("Calls") }

            Section {
                statusRows(c)
                if !c.available {
                    Label("Not available in this build", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
                HStack {
                    if c.enabled {
                        Button("Set Up Again\u{2026}") { model.openCallAudioSetup() }
                        Button("Turn Off\u{2026}", role: .destructive) { confirmOff = true }
                    } else {
                        Button("Set Up\u{2026}") { model.openCallAudioSetup() }
                            .buttonStyle(.borderedProminent).disabled(!c.available || model.state.link != .connected)
                        if model.state.link != .connected { Text("Needs your phone").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                }
            } header: {
                HStack(spacing: 5) {
                    Text("Call audio")
                    InfoButton(c.enabled
                               ? "Turning it off undoes everything: wireless debugging disconnects and the permission is removed. Then you can switch Developer options off."
                               : "Takes about a minute. Your phone and this Mac need the same Wi\u{2011}Fi.")
                }
            }

            if c.enabled, let tier = c.prefs.tier, tier != .none {
                Section {
                    Toggle("Use Mac audio when I answer here", isOn: Binding(get: { c.prefs.routeOnAnswer }, set: { c.setRouteOnAnswer($0) }))
                    if tier == .full { talkRows(c) }
                } header: { Text("During calls") } footer: {
                    Text(tier == .full ? "Switch any time in the call panel." : "Listen only. Talk into your phone.")
                }
            }

            if c.prefs.talkCheckPending {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Did they hear you?", systemImage: "mic.fill").font(.system(size: 13, weight: .semibold))
                        Text("Asked once, after your first Mac call.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button("Yes") { c.answerTalkCheck(heard: true) }.buttonStyle(.borderedProminent)
                            Button("No") { c.answerTalkCheck(heard: false) }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section {
                Picker("Speaker", selection: Binding(get: { c.prefs.outputUID ?? "" }, set: { c.setDevices(output: .some($0.isEmpty ? nil : $0), input: nil) })) {
                    Text("System default").tag("")
                    ForEach(outputs) { Text($0.name).tag($0.uid) }
                }
                Picker("Microphone", selection: Binding(get: { c.prefs.inputUID ?? "" }, set: { c.setDevices(output: nil, input: .some($0.isEmpty ? nil : $0)) })) {
                    Text("System default").tag("")
                    ForEach(inputs) { Text($0.name).tag($0.uid) }
                }
                .disabled(c.prefs.tier != nil && c.prefs.tier != .full)
            } header: { Text("Devices") }
        }
        .onAppear { outputs = AudioDevices.outputs(); inputs = AudioDevices.inputs() }
        .confirmationDialog("Turn off call audio?", isPresented: $confirmOff, titleVisibility: .visible) {
            Button("Turn off", role: .destructive) { c.turnOff() }
        } message: {
            Text("Wireless debugging disconnects. Calls keep working on your phone.")
        }
    }

    @ViewBuilder
    private func talkRows(_ c: CallAudioController) -> some View {
        Toggle("Talk from Mac (experimental)", isOn: Binding(get: { c.prefs.talkEnabled }, set: { c.setTalkEnabled($0) }))
        if c.prefs.talkConfirmed == true {
            Label("Confirmed", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
        } else if c.prefs.talkConfirmed == false {
            Label("Turned off. They couldn\u{2019}t hear you.", systemImage: "mic.slash").font(.callout).foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func statusRows(_ c: CallAudioController) -> some View {
        row("Call audio", c.enabled ? ("On", .green) : ("Off", .gray))
        if c.enabled || c.prefs.tier != nil {
            LabeledContent("Your phone supports") {
                Text(c.prefs.tier.map(TierCopy.title) ?? "Checking\u{2026}").foregroundStyle(.secondary)
            }
            if let t = c.prefs.tier, t == .none {
                Text(TierCopy.detail(.none)).font(.callout).foregroundStyle(.secondary)
            }
        }
        if c.enabled {
            row("Wireless debugging", wireless(c))
            LabeledContent("Last connected") {
                Text(c.prefs.lastConnected.map { c.adbState == .connected ? "Now" : Fmt.lastSeen($0) } ?? "Never").foregroundStyle(.secondary)
            }
            if !c.prefs.keepAliveGranted {
                Label("Wireless debugging may switch itself off", systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    .help("Android didn\u{2019}t allow the keep-alive. Set up again if calls stop appearing here.")
            }
        }
    }

    private func wireless(_ c: CallAudioController) -> (String, Color) {
        switch c.adbState {
        case .connected: return ("Connected", .green)
        case .searching: return ("Waiting\u{2026}", .orange)
        case .unreachable: return ("Retrying\u{2026}", .orange)
        case .off: return ("Off", .gray)
        }
    }

    private func row(_ title: String, _ s: (String, Color)) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) { Circle().fill(s.1).frame(width: 7, height: 7); Text(s.0).foregroundStyle(.secondary) }
        }
    }
}

import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import MydroidCore

struct PopoverView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        ZStack {
            Group {
                if model.isPaired { pairedContent } else { UnpairedView() }
            }
            .blur(radius: model.previewPhoto == nil ? 0 : 6)
            .allowsHitTesting(model.previewPhoto == nil)

            if let photo = model.previewPhoto {
                PhotoPreview(file: photo).transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
            if dropTargeted { DropOverlay() }
        }
        .frame(width: 372)
        .fitMenuBarWindow()
        .environment(model.ui)
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                Text(t)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.thickMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
                    .padding(.bottom, 52)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.25), value: model.toast)
        .animation(.spring(duration: 0.4, bounce: 0.15), value: model.previewPhoto)
        .onDrop(of: [.fileURL, .url], isTargeted: $dropTargeted) { providers in
            guard model.isPaired else { return false }
            let group = DispatchGroup()
            var urls: [URL] = []
            for p in providers {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { urls.append(url) } }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                let files = urls.filter(\.isFileURL)
                if !files.isEmpty { model.send(.files(files)) }
                // Web links open on the phone; anything that isn't http, https or mailto is ignored.
                for u in urls where !u.isFileURL { if LinkPolicy.allowed(u) { model.send(.link(u)) } }
            }
            return true
        }
    }

    private var pairedContent: some View {
        VStack(spacing: 0) {
            HeaderView()
            VStack(spacing: 12) {
                ClickerReadyLine()
                OngoingCallRow()
                CodeCardsSection(list: model.state.notifications)
                RecoveryView()
                CallAudioPendingCard()
                TalkCheckCard()
                NowPlayingSection()
                NotificationsSection()
                QuickActions()
                TransfersView()
                CameraRollRow()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            Divider().opacity(0.5)
            FooterView()
        }
    }
}

// MARK: Header

struct HeaderView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.state
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(LinearGradient(colors: [.brand, .brand.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                Image(systemName: "iphone.gen3").font(.system(size: 17, weight: .medium)).foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.phone?.name ?? "Your phone").font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(dotColor).frame(width: 6, height: 6)
                    Text(statusLine).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if s.link == .connected, let b = s.phone?.battery {
                VStack(alignment: .trailing, spacing: 3) {
                    BatteryView(level: b, charging: s.phone?.charging ?? false, lowPower: s.phone?.lowPowerMode ?? false)
                    if s.phone?.lowPowerMode == true {
                        Text("Battery saver").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.yellow.opacity(0.95))
                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                            .background(Color.yellow.opacity(0.18), in: Capsule())
                    }
                }
            }
            SettingsGearButton()
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 12)
        .animation(.spring(duration: 0.4), value: s.link)
    }

    private var dotColor: Color {
        switch model.state.link {
        case .connected: return model.state.fixes.isEmpty ? .green : .orange
        case .searching: return .orange
        case .unpaired: return .gray
        }
    }

    private var statusLine: String {
        let s = model.state
        switch s.link {
        case .connected:
            switch s.phone?.network {
            case .wifi: return "Connected over Wi\u{2011}Fi"
            case .cellular: return "Connected over mobile data"
            default: return "Connected"
            }
        case .searching: return "Looking for your phone\u{2026}"
        case .unpaired: return "Not paired"
        }
    }
}

/// A plain, always-visible way into Settings (the popover header and the full window's toolbar).
struct SettingsGearButton: View {
    @Environment(AppModel.self) private var model
    @State private var hover = false

    var body: some View {
        Button { model.openSettings(); NSApp.activate(ignoringOtherApps: true) } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(hover ? Color.primary : Color.secondary)
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(hover ? 0.10 : 0.06), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .keyboardShortcut(",")
        .help("Settings (\u{2318},)")
        .accessibilityLabel("Settings")
    }
}

struct UnpairedView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right").font(.system(size: 34)).foregroundStyle(Color.brand)
            Text("Pair your Android").font(.headline)
            Text("Notifications, photos, files and clipboard, right on your Mac.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Set Up") { model.openSetup() }.buttonStyle(.borderedProminent).controlSize(.large)
            HStack(spacing: 14) {
                Button { model.openSettings(); NSApp.activate(ignoringOtherApps: true) } label: { Label("Settings", systemImage: "gearshape") }
                    .keyboardShortcut(",")
                Button("Quit Mydroid") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(24)
    }
}

// MARK: Recovery

struct RecoveryView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let s = model.state
        VStack(spacing: 8) {
            if s.link == .searching { SearchingCard() }
            ForEach(s.fixes, id: \.self) { FixCard(kind: $0) }
            if model.isPaired, model.bluetooth.needsAttention { BluetoothHintCard() }
            if s.link == .connected, model.remote.needsAccessCard { AccessibilityRecoveryCard() }
            if let err = s.listenerError {
                RecoveryCard(icon: "wifi.exclamationmark", tint: .orange, title: "Can\u{2019}t listen for your phone",
                             message: err) { EmptyView() }
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.2), value: s.fixes)
        .animation(.spring(duration: 0.4, bounce: 0.2), value: s.link)
        .animation(.spring(duration: 0.4, bounce: 0.2), value: model.remote.needsAccessCard)
    }
}

struct RecoveryCard<Trailing: View>: View {
    var icon: String
    var tint: Color
    var title: String
    var message: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(message).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                trailing().padding(.top, 3)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }
}

/// One hint when Bluetooth can't carry the "Mac is nearby" signal.
struct BluetoothHintCard: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        RecoveryCard(icon: "antenna.radiowaves.left.and.right", tint: .orange, title: model.bluetooth == .unauthorized ? "Bluetooth access needed" : "Bluetooth is off",
                     message: "Your phone uses it to tell this Mac is nearby.") {
            Button("Open Bluetooth Settings") { model.openBluetoothSettings() }.controlSize(.small).buttonStyle(.bordered)
        }
    }
}

struct SearchingCard: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        RecoveryCard(icon: "antenna.radiowaves.left.and.right", tint: .orange, title: "Looking for your phone\u{2026}",
                     message: "Use the same Wi\u{2011}Fi as this Mac.") {
            if let seen = model.state.lastSeen {
                TimelineView(.periodic(from: .now, by: 20)) { _ in
                    Text("Last seen \(Fmt.lastSeen(seen))").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct FixCard: View {
    @Environment(AppModel.self) private var model
    var kind: FixKind
    @State private var asked = false
    var body: some View {
        let phone = model.phoneName
        let c = copy(phone)
        RecoveryCard(icon: "exclamationmark.triangle.fill", tint: .orange, title: c.0, message: c.1) {
            Button {
                model.fix(kind)
                asked = true
                Task { try? await Task.sleep(for: .seconds(8)); asked = false }
            } label: {
                Label(asked ? "Check your phone" : "Fix on \(phone)", systemImage: asked ? "hand.point.up.left" : "arrow.up.forward.app")
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .disabled(asked)
        }
    }
    private func copy(_ phone: String) -> (String, String) {
        switch kind {
        case .background: return ("Background activity restricted", "Check Battery settings for Mydroid on your \(phone).")
        case .notifications: return ("Notifications are off", "Allow notification access on your \(phone).")
        case .photos: return ("Camera roll needs access", "Allow photo access on your \(phone).")
        case .calls: return ("Call alerts need access", "Allow call access on your \(phone).")
        case .sms: return ("Text messages need access", "Allow text access on your \(phone).")
        case .devoptions: return ("Developer options", "Open Developer options on your \(phone).")
        }
    }
}

// MARK: Notifications

struct NotificationsSection: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        NotificationsPanel(list: model.state.notifications, enabled: model.state.settings.notifications)
    }
}

struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct EmptyNote: View {
    var icon: String
    var title: String
    var subtitle: String?
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 22, weight: .light)).foregroundStyle(.tertiary).symbolRenderingMode(.hierarchical)
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 16)
    }
}

// MARK: Quick actions, transfers, camera roll

struct QuickActions: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let connected = model.state.link == .connected
        HStack(spacing: 8) {
            Button { model.chooseFilesToSend() } label: {
                tile("paperplane.fill", "Send File")
            }
            .buttonStyle(PressableTileStyle())
            .help("Or drop files anywhere on this window")

            Button { model.setSetting(\.clipboard, !model.state.settings.clipboard) } label: {
                tile(model.state.settings.clipboard ? "doc.on.clipboard.fill" : "doc.on.clipboard",
                     model.state.settings.clipboard ? "Clipboard on" : "Clipboard off")
            }
            .buttonStyle(PressableTileStyle(active: model.state.settings.clipboard))
            .help("Share copied text between this Mac and your phone")

            Button { model.openMainWindow(.calls) } label: {
                tile("phone.fill", "Call")
            }
            .buttonStyle(PressableTileStyle())
            .help("Open the dial pad and recent calls")

            Button { model.toggleFind() } label: {
                tile(model.findingPhone ? "bell.and.waves.left.and.right.fill" : "location.magnifyingglass",
                     model.findingPhone ? "Stop ringing" : "Find phone")
            }
            .buttonStyle(PressableTileStyle(active: model.findingPhone))
            .symbolEffect(.pulse, isActive: model.findingPhone)
        }
        .disabled(!connected)
        .opacity(connected ? 1 : 0.5)
        .animation(.easeOut(duration: 0.2), value: connected)
    }

    private func tile(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium)).symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
            Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(.primary)
    }
}

struct TransfersView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let outgoing = model.state.transfers.filter(\.outgoing)
        if !outgoing.isEmpty {
            VStack(spacing: 6) {
                ForEach(outgoing) { t in
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.circle.fill").foregroundStyle(Brand.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Sending \(t.name)").font(.system(size: 12, weight: .medium)).lineLimit(1)
                            ProgressView(value: t.fraction).progressViewStyle(.linear).tint(Brand.accent)
                        }
                        Text("\(Int(t.fraction * 100))%").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.35), value: outgoing.map(\.xid))
        }
    }
}

struct CameraRollRow: View {
    @Environment(AppModel.self) private var model
    @State private var thumb: NSImage?
    @State private var hover = false

    var body: some View {
        let s = model.state
        let photo = s.latestPhoto
        Button {
            if let photo { model.previewPhoto = photo }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.08))
                    if let thumb { Image(nsImage: thumb).resizable().scaledToFill() }
                    else { Image(systemName: "photo.on.rectangle.angled").foregroundStyle(.tertiary).font(.system(size: 16)) }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Camera roll").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        statusLabel
                    }
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                if photo != nil { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary) }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(hover ? 0.08 : 0.05)))
        }
        .buttonStyle(.plain)
        .disabled(photo == nil)
        .onHover { hover = $0 }
        .task(id: photo?.url) {
            guard let u = photo?.url else { thumb = nil; return }
            thumb = await Task.detached { thumbnail(for: u) }.value
        }
    }

    @ViewBuilder private var statusLabel: some View {
        let s = model.state
        if !s.settings.photos {
            Text("Off").font(.system(size: 11.5)).foregroundStyle(.secondary)
        } else if s.link == .connected, s.features.photos == .needsPermission {
            Label("Needs access", systemImage: "exclamationmark.circle.fill").font(.system(size: 11.5)).foregroundStyle(.orange)
        } else if s.link != .connected {
            Text("Paused").font(.system(size: 11.5)).foregroundStyle(.secondary)
        } else if s.photoSyncing {
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Syncing").font(.system(size: 11.5)).foregroundStyle(.secondary) }
        } else {
            Label("Up to date", systemImage: "checkmark").labelStyle(.titleAndIcon)
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.green)
        }
    }

    private var subtitle: String {
        guard let p = model.state.latestPhoto else {
            return model.state.settings.photos ? "New photos land in \(model.photosFolderLabel)" : "Turn on in Settings"
        }
        return "\(p.name) \u{00B7} \(Fmt.relative(p.taken ?? p.savedAt)) \u{00B7} Saved to \(model.photosFolderLabel)"
    }
}

struct PhotoPreview: View {
    @Environment(AppModel.self) private var model
    var file: SavedFile
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button { model.previewPhoto = nil } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(Brand.accent).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(file.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Spacer()
                Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: { Image(systemName: "folder") }
                    .buttonStyle(.plain).help("Show in Finder")
            }
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06))
                if let image { Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)) }
                else { ProgressView() }
            }
            .frame(height: 300)
            .onTapGesture(count: 2) { NSWorkspace.shared.open(file.url) }
            VStack(spacing: 2) {
                Text("Saved to \(model.photosFolderLabel)").font(.system(size: 12)).foregroundStyle(.secondary)
                Text((file.taken ?? file.savedAt).formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            HStack {
                Button("Open") { NSWorkspace.shared.open(file.url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
            }.controlSize(.regular)
        }
        .padding(14)
        .frame(width: 372)
        .background(.regularMaterial)
        .task(id: file.url) {
            let u = file.url
            image = await Task.detached { thumbnail(for: u, maxPixel: 1200) }.value
        }
    }
}

struct DropOverlay: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Brand.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            VStack(spacing: 6) {
                Image(systemName: "arrow.down.doc.fill").font(.system(size: 30)).foregroundStyle(Brand.accent)
                Text("Drop to send to \(model.phoneName)").font(.system(size: 13, weight: .semibold))
            }
        }
        .padding(8)
        .transition(.opacity)
    }
}

// MARK: Footer

struct FooterView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack {
            Button { model.openMainWindow() } label: {
                Label("Open Mydroid", systemImage: "macwindow").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain).foregroundStyle(Brand.accent)
            .help("Messages, Photos, Calls and Files (\u{2303}\u{2325}M)")
            Spacer()
            Button { NSApp.terminate(nil) } label: { Text("Quit Mydroid").font(.system(size: 11.5)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .keyboardShortcut("q")
                .help("Quit Mydroid (\u{2318}Q)")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}


/// Shown in the popover while a call is in progress and its floating panel has been hidden.
struct OngoingCallRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let call = model.state.call, call.phase != .ended, model.hiddenCalls.contains(call.callId) {
            let audio = model.callAudio
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "phone.fill").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white).frame(width: 28, height: 28).background(Color.green, in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(call.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if call.phase == .active {
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                let t = Int(max(0, ctx.date.timeIntervalSince(call.startedAt)))
                                Text(String(format: "%@ \u{00B7} %d:%02d", audio.routedToMac ? (audio.prefs.tier == .listen ? "Listening on your Mac" : "On your Mac") : "On your phone", t / 60, t % 60))
                                    .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        } else {
                            Text(call.incoming ? "Ringing on your phone" : "Calling\u{2026}").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Button("Show") { model.showCallPanel() }.buttonStyle(.bordered).controlSize(.small)
                    Button { model.hub.callAction(call.phase == .ringing && call.incoming ? "decline" : "end") } label: {
                        Image(systemName: "phone.down.fill").foregroundStyle(.white).frame(width: 26, height: 22)
                            .background(Color.red, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("End call")
                }
                if call.phase == .active, audio.showsRouteSwitch {
                    AudioRouteSwitch()
                    if audio.routedToMac { RoutedAudioStatus() }
                }
            }
            .padding(10)
            .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

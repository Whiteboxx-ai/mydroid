import SwiftUI
import AppKit
import MydroidCore

/// The Window scene's root. It owns the Dock/Cmd-Tab lifecycle, which `MainWindowView` leaves out so the view
/// can be rendered off-screen.
struct MainWindowRoot: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        MainWindowView()
            .onAppear { UIDiagnostics.log("main window appeared section=\(model.section)"); model.mainWindowAppeared() }
            .onDisappear { model.mainWindowDisappeared() }
            .onChange(of: model.messages.unreadCount) { _, _ in model.updateDockBadge() }
    }
}

/// Messages, Photos, Calls and Files on one window, with the phone's status at the bottom of the sidebar.
struct MainWindowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 208, max: 250)
        } detail: {
            MainDetailView()
                .navigationTitle(model.section.title)
        }
        .frame(minWidth: 960, minHeight: 620)
        .overlay { WindowToast() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.openSettings() } label: { Label("Settings", systemImage: "gearshape") }
                    .help("Settings (\u{2318},)")
            }
        }
    }
}

/// The right-hand side of the window: the selected section.
///
/// Kept deliberately plain. With `.id(section)` + a transition + the toast overlay stacked on a `Group` here,
/// macOS laid the *sidebar* column out taller than the window: its rows slid under the title bar, where
/// clicks hit the title bar instead of the list. The toast now lives on the window (`MainWindowView`).
struct MainDetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if !model.isPaired {
                StateView(icon: "iphone.gen3.radiowaves.left.and.right", title: "Pair your Android",
                          message: "Messages, photos, calls and files appear here.", tint: .brand) {
                    Button("Set Up") { model.openSetup() }.buttonStyle(.borderedProminent).controlSize(.large)
                }
            } else {
                switch model.section {
                case .messages: MessagesView()
                case .photos: PhotosView()
                case .calls: CallsView()
                case .files: FilesView()
                }
            }
        }
        // minHeight 0 matters: without it, a vertically fixed-size Text anywhere in the detail (e.g. a
        // multi-line empty-state message) raised the split view's minimum height and macOS laid the
        // sidebar column out taller than the window, pushing its rows under the title bar.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }
}

/// Short confirmations ("Saved to Pictures") shown at the bottom of the window.
struct WindowToast: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack {
            Spacer()
            if let t = model.toast {
                Text(t)
                    .font(.system(size: 12.5, weight: .medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.thickMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .animation(.spring(duration: 0.4, bounce: 0.25), value: model.toast)
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: Binding(get: { Optional(model.section) }, set: {
            UIDiagnostics.log("sidebar set \(String(describing: $0)) from \(model.section)")
            if let v = $0 { model.section = v }
        })) {
            ForEach(MainSection.allCases) { s in
                Label(s.title, systemImage: s.icon)
                    .tag(s)
                    .badge(badge(s))
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                SidebarSettingsButton()
                PhoneStatusCard()
            }
        }
    }

    private func badge(_ s: MainSection) -> Int {
        switch s {
        case .messages: return model.messages.unreadCount
        case .calls: return 0
        default: return 0
        }
    }
}

/// "Settings" at the bottom of the sidebar, above the phone. Not a section: it opens the Settings window.
struct SidebarSettingsButton: View {
    @Environment(AppModel.self) private var model
    @State private var hover = false

    var body: some View {
        Button { model.openSettings() } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape").font(.system(size: 13, weight: .regular)).frame(width: 18)
                Text("Settings").font(.system(size: 13))
                Spacer(minLength: 0)
                Text("\u{2318},").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.primary.opacity(hover ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .padding(.horizontal, 8).padding(.bottom, 6)
        .accessibilityLabel("Settings")
    }
}

/// The phone at the bottom of the sidebar: name, battery, connection.
struct PhoneStatusCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.state
        VStack(spacing: 0) {
            Divider().opacity(0.6)
            HStack(spacing: 9) {
                ZStack {
                    Circle().fill(LinearGradient(colors: [.brand, .brand.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                    Image(systemName: "iphone.gen3").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.phone?.name ?? "Your phone").font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 4) {
                        Circle().fill(dot).frame(width: 6, height: 6)
                        Text(status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if s.link == .connected, let b = s.phone?.battery {
                    BatteryView(level: b, charging: s.phone?.charging ?? false, lowPower: s.phone?.lowPowerMode ?? false)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .background(.bar)
    }

    private var dot: Color {
        switch model.state.link {
        case .connected: return model.state.fixes.isEmpty ? .green : .orange
        case .searching: return .orange
        case .unpaired: return .gray
        }
    }

    private var status: String {
        switch model.state.link {
        case .connected:
            switch model.state.phone?.network {
            case .wifi: return "Wi\u{2011}Fi"
            case .cellular: return "Mobile data"
            default: return "Connected"
            }
        case .searching: return "Not connected"
        case .unpaired: return "Not paired"
        }
    }
}

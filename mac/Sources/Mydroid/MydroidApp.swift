import SwiftUI
import AppKit
import MydroidCore

@main
struct MydroidApp: App {
    @State private var model = AppModel.shared

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.servicesProvider = ServicesProvider.shared
        NSUpdateDynamicServices()
        URLSchemeHandler.shared.register()
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environment(model)
        } label: {
            MenuBarLabel().environment(model)
        }
        .menuBarExtraStyle(.window)

        Window("Call Audio", id: "callaudio") {
            CallAudioSetupView().environment(model)
                .onDisappear { model.callAudio.cancelSetup() }
        }
        .windowResizability(.contentSize)

        Window("Import from Google Authenticator", id: "authimport") {
            CameraImportRoot().environment(model)
        }
        .windowResizability(.contentSize)

        Window("Set up Mydroid", id: "setup") {
            SetupView().environment(model)
                .onDisappear { model.hub.cancelPairing() }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Window("Mydroid Settings", id: "settings") {
            SettingsView(initial: model.settingsTab).environment(model)
        }
        .windowResizability(.contentSize)

        // The full window: Messages, Photos, Calls and Files. Open it from the popover, or with \u{2303}\u{2325}M.
        Window("Mydroid", id: "main") {
            MainWindowRoot().environment(model).environment(model.ui)
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings\u{2026}") { model.openSettings() }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button("New Message") { model.openMainWindow(.messages); model.messages.startNewMessage() }
                    .keyboardShortcut("n")
                    .disabled(model.state.link != .connected)
                Button("Send File\u{2026}") { model.chooseFilesToSend() }
                    .keyboardShortcut("o")
                    .disabled(model.state.link != .connected)
            }
            CommandMenu("Go") {
                ForEach(Array(MainSection.allCases.enumerated()), id: \.element) { i, s in
                    Button(s.title) { model.openMainWindow(s) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                }
            }
        }
    }
}

/// The menu bar icon. Reflects state: connected, searching, needs attention. It also hosts the
/// launch-time hook that opens Setup the first time (a MenuBarExtra label is alive from launch).
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.pulse, isActive: model.menuIcon == .searching)
            let unread = model.state.notifications.items.count
            if unread > 0 && model.state.link == .connected { Text("\(unread)").font(.system(size: 11, weight: .semibold)).monospacedDigit() }
            if model.prefs.showBatteryInMenuBar, model.state.link == .connected, let b = model.state.phone?.battery {
                Text("\(b)%").font(.system(size: 11, weight: .medium)).monospacedDigit()
            }
        }
        .accessibilityLabel(accessibility)
        .task {
            model.openWindowAction = { id in
                openWindow(id: id)
                NSApp.activate(ignoringOtherApps: true)
            }
            // Dev hook: open the main window at launch (used to check window layout in an unpaired scratch copy).
            if ProcessInfo.processInfo.environment["MYDROID_OPEN_MAIN"] == "1" {
                try? await Task.sleep(for: .milliseconds(300))
                model.openMainWindow(.calls)
                return
            }
            if !model.isPaired {
                try? await Task.sleep(for: .milliseconds(300))
                model.openSetup()
            }
        }
    }

    private var symbol: String {
        switch model.menuIcon {
        case .connected: return Self.first(["iphone.gen3.radiowaves.left.and.right", "iphone.radiowaves.left.and.right", "iphone"])
        case .searching: return Self.first(["iphone.gen3.slash", "iphone.slash", "iphone"])
        case .attention: return Self.first(["iphone.gen3.badge.exclamationmark", "iphone.badge.exclamationmark", "exclamationmark.triangle"])
        case .idle: return Self.first(["iphone.gen3", "iphone"])
        }
    }

    private var accessibility: String {
        switch model.menuIcon {
        case .connected: return "Mydroid, connected"
        case .searching: return "Mydroid, looking for your phone"
        case .attention: return "Mydroid, needs attention"
        case .idle: return "Mydroid"
        }
    }

    private static func first(_ names: [String]) -> String {
        names.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil } ?? "iphone"
    }
}

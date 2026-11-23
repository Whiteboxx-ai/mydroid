import SwiftUI
import AppKit
import MydroidCore
import MydroidNM

// Settings > Authenticator (PROTOCOL.md 14.3).

struct AuthenticatorSettings: View {
    @Environment(AppModel.self) private var model
    @State private var recording = false
    @State private var monitor: Any?
    @State private var setupBrowser: ChromiumBrowser?

    var body: some View {
        @Bindable var m = model
        let inst = model.extensionInstaller
        Form {
            Section {
                LabeledContent {
                    let s = phoneState
                    StatusText(text: s.text, color: s.color)
                } label: {
                    InfoLabel("Your phone", icon: "iphone.gen3",
                              info: "Your accounts and secrets stay on your phone. This Mac only receives the current code, after you approve it there (unless you turned on auto-approve).")
                }
                LabeledContent {
                    Text("Always on").foregroundStyle(.secondary)
                } label: {
                    InfoLabel("Site checks", icon: "lock.shield",
                              info: "Codes are filled only on a site your phone has linked to that account. New sites make you pick the account, and lookalike addresses (like paypa1.com) get a warning.")
                }
            } header: { Text("Codes from your phone") }

            Section {
                LabeledContent {
                    Button("Import with Camera\u{2026}") { model.openCameraImport() }
                        .controlSize(.small).disabled(model.state.link != .connected)
                } label: {
                    InfoLabel("Google Authenticator", icon: "camera.viewfinder",
                              info: "It hides export codes from screenshots. Show them to this Mac\u{2019}s camera and Mydroid hands them to your phone to approve. Nothing is saved on this Mac.")
                }
            } header: { Text("Add accounts") }

            Section {
                ForEach(inst.rows.filter { $0.present || $0.ready }) { row in
                    ExtensionRow(row: row) { setupBrowser = row.browser }
                }
                if let e = inst.lastError { Text(e).font(.caption).foregroundStyle(.red) }
                if !inst.helperAvailable {
                    Label("Not available in this build", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if inst.extensionFolder != nil {
                    LabeledContent {
                        Button("Show in Finder") { inst.revealExtensionFolder() }.controlSize(.small)
                    } label: { Label("Extension folder", systemImage: "folder") }
                }
            } header: { Text("Browser extension") } footer: {
                Text("Safari and others: use the shortcut below.")
            }

            Section {
                InfoToggle("Fill with a keyboard shortcut", isOn: $m.prefs.authShortcutEnabled,
                           info: "Reads the front browser\u{2019}s address, asks your phone and types the code. Needs Accessibility, and macOS asks once to let Mydroid read the address.")
                LabeledContent("Shortcut") {
                    HStack(spacing: 8) {
                        Text(recording ? "Press the new shortcut\u{2026}" : m.prefs.authShortcut.display)
                            .font(.system(size: 12.5, weight: .medium, design: .rounded))
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(.primary.opacity(recording ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Button(recording ? "Cancel" : "Change\u{2026}") { recording ? stopRecording() : startRecording() }.controlSize(.small)
                        if m.prefs.authShortcut != .standard && !recording {
                            Button("Reset") { m.prefs.authShortcut = .standard }.controlSize(.small)
                        }
                    }
                }
                .disabled(!m.prefs.authShortcutEnabled)
                if model.authShortcutConflict && m.prefs.authShortcutEnabled {
                    Label("Another app uses this shortcut", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            } header: { Text("Keyboard shortcut") }

            if !m.prefs.authAutofillSites.isEmpty {
                Section {
                    ForEach(m.prefs.authAutofillSites, id: \.self) { site in
                        HStack {
                            Text(site).font(.system(size: 13))
                            Spacer()
                            Button { m.prefs.authAutofillSites.removeAll { $0 == site } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help("Stop filling automatically on \(site)")
                                .accessibilityLabel("Remove \(site)")
                        }
                    }
                } header: { Text("Fill automatically on") } footer: {
                    Text("You still approve each code on your phone.")
                }
            }
        }
        .onDisappear { stopRecording() }
        .onAppear { inst.refresh() }
        .sheet(item: $setupBrowser, onDismiss: { inst.refresh() }) { b in
            ExtensionSetupSheet(setup: ExtensionSetupModel(browser: b, installer: inst))
        }
    }

    private var phoneState: (text: String, color: Color) {
        switch model.state.link {
        case .connected: return ("Connected", .green)
        case .searching: return ("Not connected", .orange)
        default: return ("Not paired", .secondary)
        }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stopRecording(); return nil }                     // Esc
            if let k = AuthShortcutKey.from(event: e) { model.prefs.authShortcut = k; stopRecording(); return nil }
            return nil                                                              // swallow keys without a modifier while recording
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct ExtensionRow: View {
    let row: ExtensionInstaller.Row
    var setUp: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                if row.ready {
                    Label("Ready", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon).foregroundStyle(.green)
                    Button("Set Up Again\u{2026}", action: setUp).controlSize(.small)
                } else {
                    Button("Set Up\u{2026}", action: setUp).controlSize(.small).buttonStyle(.borderedProminent)
                }
            }
        } label: {
            Label {
                Text(row.browser.displayName)
            } icon: {
                Image(systemName: "globe").foregroundStyle(Color.secondary)
            }
        }
    }
}

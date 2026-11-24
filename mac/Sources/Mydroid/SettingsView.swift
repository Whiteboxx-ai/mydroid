import SwiftUI
import AppKit
import MydroidCore

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, notifications, photos, clipboard, media, calls, quickShare, files, authenticator, remote, walkAway, phone
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .notifications: return "Notifications"
        case .photos: return "Photos"
        case .clipboard: return "Clipboard"
        case .media: return "Media"
        case .calls: return "Calls"
        case .quickShare: return "Quick Share"
        case .files: return "Files"
        case .authenticator: return "Authenticator"
        case .remote: return "Remote"
        case .walkAway: return "Walk-away lock"
        case .phone: return "Phone"
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .notifications: return "bell.badge"
        case .photos: return "photo.on.rectangle"
        case .clipboard: return "doc.on.clipboard"
        case .media: return "play.circle"
        case .calls: return "phone"
        case .quickShare: return "arrow.down.circle"
        case .files: return "folder"
        case .authenticator: return "key.viewfinder"
        case .remote: return "cursorarrow.click.2"
        case .walkAway: return "figure.walk"
        case .phone: return "iphone.gen3"
        }
    }
}

/// The Settings window: a sidebar of sections and a grouped form for each.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: SettingsTab
    private let height: CGFloat

    init(initial: SettingsTab = .general, height: CGFloat = 560) { _tab = State(initialValue: initial); self.height = height }

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsTab.allCases, selection: $tab) { t in
                Label(t.title, systemImage: t.icon).tag(t)
            }
            .listStyle(.sidebar)
            .frame(width: 190)
            Divider()
            Group {
                switch tab {
                case .general: GeneralSettings()
                case .notifications: NotificationSettings()
                case .photos: PhotoSettings()
                case .clipboard: ClipboardSettings()
                case .media: MediaSettings()
                case .calls: CallSettings()
                case .quickShare: QuickShareSettingsView()
                case .files: FileShareSettingsView()
                case .authenticator: AuthenticatorSettings()
                case .remote: RemoteSettings()
                case .walkAway: WalkAwaySettings()
                case .phone: PhoneSettings()
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 740, height: height)
        .onChange(of: model.settingsTab) { _, t in tab = t }
    }
}

private func syncBinding(_ model: AppModel, _ key: WritableKeyPath<SyncSettings, Bool>) -> Binding<Bool> {
    Binding(get: { model.state.settings[keyPath: key] }, set: { model.setSetting(key, $0) })
}

// MARK: General

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                if let note = model.loginItemNote { Text(note).font(.caption).foregroundStyle(.orange) }
                Toggle("Show phone battery in menu bar", isOn: $m.prefs.showBatteryInMenuBar)
            }

            Section {
                Picker("Links from your phone", selection: $m.prefs.linksOpenAutomatically) {
                    Text("Show a banner").tag(false)
                    Text("Open in browser").tag(true)
                }
            } footer: {
                Text("Only web and email links open.")
            }

            Section {
                LabeledContent {
                    Text("Services \u{203A} Send to Phone").foregroundStyle(.secondary)
                } label: {
                    InfoLabel("Send to phone", icon: "paperplane",
                              info: "Select text, a link or files, then choose Services \u{203A} Send to Phone. You can also drag files onto the Mydroid menu, or use mydroid://send?url=\u{2026} in Shortcuts.")
                }
                LabeledContent("Mydroid") {
                    Button("Quit Mydroid") { NSApp.terminate(nil) }.controlSize(.small)
                        .help("Mydroid keeps running in the menu bar when you close its windows")
                }
            }
        }
    }
}

// MARK: Notifications

struct NotificationSettings: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        @Bindable var m = model
        Form {
            Section {
                Toggle("Show notifications from your phone", isOn: syncBinding(model, \.notifications))
            }

            Section {
                if model.focusAvailable {
                    Toggle("Follow Focus", isOn: Binding(get: { model.prefs.followFocus }, set: { model.setFollowFocus($0) }))
                }
                InfoToggle("Quiet hours", isOn: $m.prefs.quietHours.enabled,
                           info: "Banners are hidden\(model.focusAvailable ? " during quiet hours and while a Focus is on" : " during quiet hours"). Notifications stay in the Mydroid menu.")
                if model.prefs.quietHours.enabled {
                    DatePicker("From", selection: minutesBinding(\.from), displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: minutesBinding(\.to), displayedComponents: .hourAndMinute)
                }
            } header: { Text("Do not disturb") }

            Section {
                InfoToggle("Copy codes automatically", isOn: $m.autoCopyCodes,
                           info: "Codes are copied as they arrive. They are never sent back to your phone.")
                Picker("Show code cards for", selection: $m.prefs.codeCardMinutes) {
                    Text("2 minutes").tag(2)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("30 minutes").tag(30)
                }
            } header: { Text("Verification codes") }

            Section {
                AppListSection(query: $query)
            } header: {
                HStack(spacing: 5) {
                    Text("Apps")
                    InfoButton("Turn an app off to stop its notifications from coming here. \u{201C}When clicked\u{201D} sets what clicking one does. Apps appear after their first notification.")
                }
            }
        }
    }

    private func minutesBinding(_ key: WritableKeyPath<QuietHours, Int>) -> Binding<Date> {
        Binding(get: {
            let m = model.prefs.quietHours[keyPath: key]
            return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
        }, set: {
            let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
            model.prefs.quietHours[keyPath: key] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        })
    }
}

struct AppListSection: View {
    @Environment(AppModel.self) private var model
    @Binding var query: String

    var body: some View {
        let all = model.knownApps.sorted()
        let q = query.trimmingCharacters(in: .whitespaces)
        let shown = q.isEmpty ? all : all.filter { $0.entry.name.localizedCaseInsensitiveContains(q) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search apps", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            if all.isEmpty {
                Text("No apps yet").font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
            } else if shown.isEmpty {
                Text("No apps match \u{201C}\(q)\u{201D}").font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
                ForEach(shown, id: \.pkg) { app in
                    AppRow(pkg: app.pkg, name: app.entry.name, icon: app.entry.icon)
                }
            }
        }
    }
}

/// One app in Settings > Notifications: the on/off switch (mute) and what clicking its notifications does.
struct AppRow: View {
    @Environment(AppModel.self) private var model
    var pkg: String
    var name: String
    var icon: Data?

    private var router: OpenRouter { model.ui.router }
    private var hasWeb: Bool { router.hasWebRule(forPackage: pkg) }
    private var choice: ClickBehavior {
        let b = model.prefs.clickBehavior(for: pkg)
        return b == .web && !hasWeb ? .default : b      // a stale "web" for an app without a web rule is just Default
    }

    /// What the default click does (the other choices name themselves in the menu).
    private var description: String? { choice == .default ? router.summary(forPackage: pkg) : nil }

    var body: some View {
        let muted = model.isMuted(pkg)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                AppIcon(data: icon, name: name, size: 24)
                Text(name).lineLimit(1)
                Spacer()
                Toggle(name, isOn: Binding(get: { !muted }, set: { model.setMuted(pkg, !$0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            HStack(spacing: 8) {
                Text("When clicked").font(.caption).foregroundStyle(.secondary)
                Picker("When clicked", selection: Binding(get: { choice }, set: { model.setClickBehavior($0, for: pkg) })) {
                    Text("Default").tag(ClickBehavior.default)
                    Text("Open on phone").tag(ClickBehavior.phone)
                    if hasWeb { Text("Open on web").tag(ClickBehavior.web) }
                    Text("Do nothing").tag(ClickBehavior.nothing)
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
                if let description { Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail) }
                Spacer(minLength: 0)
            }
            .padding(.leading, 34)
            .disabled(muted)
            .opacity(muted ? 0.5 : 1)
        }
        .padding(.vertical, 2)
    }
}

// MARK: Photos

struct PhotoSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        Form {
            Section {
                InfoToggle("Save photos from your phone", isOn: syncBinding(model, \.photos),
                           info: "Saves original photos. Files you receive go to Downloads.")
                LabeledContent("Folder") {
                    HStack(spacing: 6) {
                        Text(model.photosDirectory.abbreviatingHome).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            .frame(maxWidth: 220, alignment: .trailing)
                        Button("Choose\u{2026}") { model.choosePhotosFolder() }
                        Button { NSWorkspace.shared.open(model.photosDirectory) } label: { Image(systemName: "folder") }.help("Show in Finder")
                    }
                }
            }

            Section {
                InfoToggle("Also add to Apple Photos", isOn: Binding(get: { model.prefs.importToApplePhotos }, set: { model.setImportToApplePhotos($0) }),
                           info: "Mydroid can only add photos. It can't see your library.")
                if let note = model.photosAccessNote { Text(note).font(.caption).foregroundStyle(.orange) }
            }

            Section {
                Toggle("Include screenshots", isOn: Binding(get: { model.state.settings.screenshots }, set: { v in model.updateSettings { $0.screenshots = v } }))
                Toggle("Use a Screenshots folder", isOn: $m.prefs.screenshotsInSubfolder)
                    .disabled(!model.state.settings.screenshots)
            }

            Section {
                Picker("Pause syncing below", selection: Binding(
                    get: { model.state.settings.pauseBelowBattery ?? 0 },
                    set: { v in model.updateSettings { $0.pauseBelowBattery = v == 0 ? nil : v } })) {
                    Text("Never").tag(0)
                    Text("10%").tag(10)
                    Text("20%").tag(20)
                    Text("30%").tag(30)
                }
            } footer: { Text("Calls and notifications keep working.") }
        }
    }
}

// MARK: Clipboard

struct ClipboardSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Form {
            Section {
                InfoToggle("Share clipboard with your phone", isOn: syncBinding(model, \.clipboard),
                           info: "Anything a password manager marks as secret is skipped, and so are codes Mydroid copies for you. Text you send with Send to Phone always goes through.")
            } footer: {
                FooterNote("Passwords and codes are never synced.", icon: "lock.shield")
            }
        }
    }
}

// MARK: Media

struct MediaSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var m = model
        Form {
            Section {
                InfoToggle("Show now playing", isOn: Binding(get: { model.state.settings.media }, set: { v in model.updateSettings { $0.media = v } }),
                           info: "Shows what is playing on your phone in the Mydroid menu, with play, pause and skip.")
            }
            Section {
                InfoToggle("Pause phone when continuing on Mac", isOn: $m.prefs.pausePhoneOnContinue,
                           info: "Continue on Mac plays the song in Spotify here, or opens it on the web. macOS asks once to let Mydroid control Spotify.")
            } header: { Text("Continue on Mac") }
        }
    }
}

// MARK: Quick Share

/// Receiving from Android's Quick Share (Share > Quick Share > this Mac).
struct QuickShareSettingsView: View {
    @Environment(AppModel.self) private var model

    private var visible: Bool {
        switch model.prefs.quickShare.visibility {
        case .always: return true
        case .phoneConnected: return model.state.link == .connected
        case .off: return false
        }
    }

    var body: some View {
        @Bindable var m = model
        Form {
            Section {
                Picker("Show this Mac", selection: $m.prefs.quickShare.visibility) {
                    Text("Always").tag(QuickShareVisibility.always)
                    Text("When phone is connected").tag(QuickShareVisibility.phoneConnected)
                    Text("Off").tag(QuickShareVisibility.off)
                }
                LabeledContent {
                    StatusText(text: visible ? "Visible as \u{201C}\(model.macName)\u{201D}" : "Not visible", color: visible ? .green : .gray)
                } label: {
                    InfoLabel("Status", info: "On your phone, tap Share, then Quick Share, and pick \u{201C}\(model.macName)\u{201D}. Both need the same Wi\u{2011}Fi.")
                }
            } header: { Text("Visibility") }

            Section {
                LabeledContent {
                    Picker("Accept from other devices", selection: $m.prefs.quickShare.others) {
                        Text("Ask").tag(QuickShareOthers.ask)
                        Text("Never").tag(QuickShareOthers.never)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                } label: {
                    InfoLabel("Accept from others", info: "\(model.phoneName) is accepted without asking while connected. Anyone else gets a banner with a PIN to check, and is declined after 30 seconds.")
                }
            } header: { Text("Other devices") }

            Section {
                Toggle("Save images in Photos folder", isOn: $m.prefs.quickShare.imagesToPhotosFolder)
                if m.prefs.quickShare.imagesToPhotosFolder {
                    LabeledContent("Photos folder") {
                        Text(model.photosDirectory.abbreviatingHome).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            .frame(maxWidth: 260, alignment: .trailing)
                    }
                }
            } header: {
                HStack(spacing: 5) {
                    Text("Received")
                    InfoButton("Files go to Downloads and text to the clipboard. Links open as set in General.")
                }
            }
        }
    }
}

// MARK: Files

/// Which Mac folders show up in Android's Files app (PROTOCOL.md section 9).
struct FileShareSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let share = model.fileShare
        Form {
            Section {
                InfoToggle("Share Mac folders with your phone", isOn: Binding(get: { share.enabled }, set: { model.setFileShareEnabled($0) }),
                           info: "They appear as \u{201C}\(model.macName)\u{201D} in your phone's Files app while it is connected. macOS asks once to let Mydroid open Desktop, Documents or Downloads.")
            }

            Section {
                if share.roots.isEmpty {
                    Text("No folders").font(.callout).foregroundStyle(.secondary).padding(.vertical, 2)
                }
                ForEach(share.roots) { root in
                    ShareFolderRow(root: root)
                }
                Button { model.addShareFolder() } label: { Label("Add Folder\u{2026}", systemImage: "plus") }
            } header: { Text("Folders") } footer: {
                Text("Hidden files are never shared.")
            }
            .disabled(!share.enabled)
        }
    }
}

private struct ShareFolderRow: View {
    @Environment(AppModel.self) private var model
    var root: FileShareRootSetting

    var body: some View {
        let found = root.resolve()
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Image(systemName: "folder.fill").foregroundStyle(found == nil ? Color.secondary : Color.brand).font(.system(size: 16))
                VStack(alignment: .leading, spacing: 1) {
                    Text(root.name).fontWeight(.medium).lineLimit(1)
                    if found == nil {
                        Text("Not found").font(.caption).foregroundStyle(.orange)
                    } else {
                        Text((found?.url ?? URL(fileURLWithPath: root.path)).abbreviatingHome).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 6)
                Button { model.removeShareFolder(root.id) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Stop sharing \(root.name)")
            }
            Toggle("Allow saving", isOn: Binding(get: { root.writable }, set: { model.setShareWritable(root.id, $0) }))
                .toggleStyle(.switch).controlSize(.small).padding(.leading, 25).disabled(found == nil)
        }
        .padding(.vertical, 2)
    }
}

// MARK: Phone

struct PhoneSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmUnpair = false

    var body: some View {
        Form {
            if model.isPaired {
                let phone = model.state.phone
                Section {
                    LabeledContent("Name", value: phone?.name ?? model.phoneName)
                    if let md = phone?.model, !md.isEmpty, md != (phone?.name ?? model.phoneName) { LabeledContent("Model", value: md) }
                    if let b = phone?.battery, model.state.link == .connected {
                        LabeledContent("Battery") {
                            HStack(spacing: 8) {
                                BatteryView(level: b, charging: phone?.charging ?? false, lowPower: phone?.lowPowerMode ?? false)
                                if phone?.lowPowerMode == true { Text("Battery saver").foregroundStyle(.secondary) }
                            }
                        }
                    }
                    bluetoothRow
                } header: { Text("Your phone") }

                Section("Status") { StatusRows() }

                Section {
                    LabeledContent {
                        Button(model.findingPhone ? "Stop Ringing" : "Ring") { model.toggleFind() }
                            .disabled(model.state.link != .connected)
                    } label: {
                        InfoLabel("Find phone", info: "Plays a loud sound on your phone, even on silent, until you stop it.")
                    }
                    LabeledContent("Pair a different phone") {
                        Button("Pair\u{2026}") { model.openSetup() }
                    }
                    LabeledContent("Unpair") {
                        Button("Unpair\u{2026}", role: .destructive) { confirmUnpair = true }
                    }
                }
            } else {
                Section {
                    LabeledContent("No phone paired") { Button("Set up\u{2026}") { model.openSetup() } }
                }
            }
        }
        .confirmationDialog("Unpair \(model.phoneName)?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { model.unpair() }
        } message: { Text("Notifications, photos and files stop until you pair again.") }
    }

    private var bluetoothRow: some View {
        let b = model.bluetoothSummary
        return LabeledContent {
            HStack(spacing: 6) {
                Circle().fill(b.ok ? Color.green : (model.bluetooth.needsAttention ? Color.orange : Color.gray)).frame(width: 7, height: 7)
                Text(b.text).foregroundStyle(.secondary)
                if model.bluetooth.needsAttention { Button("Open Settings") { model.openBluetoothSettings() }.controlSize(.small) }
            }
        } label: {
            Text("Bluetooth")
        }
        .help("Only tells your phone this Mac is nearby. No data goes over Bluetooth.")
    }
}

/// Plain-language status: never a raw error.
struct StatusRows: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let s = model.state
        row("Connection", icon: "iphone.gen3", state: connection(s))
        row("Camera roll", icon: "photo.on.rectangle", state: photos(s))
        row("Notifications", icon: "bell", state: notifications(s))
    }

    private struct RowState { var text: String; var color: Color }

    private func row(_ title: String, icon: String, state: RowState) -> some View {
        LabeledContent {
            HStack(spacing: 6) { Circle().fill(state.color).frame(width: 7, height: 7); Text(state.text).foregroundStyle(.secondary) }
        } label: { Label(title, systemImage: icon) }
    }

    private func connection(_ s: HubState) -> RowState {
        switch s.link {
        case .connected: return RowState(text: "Connected", color: .green)
        case .searching:
            if let seen = s.lastSeen { return RowState(text: "Last seen \(Fmt.lastSeen(seen))", color: .orange) }
            return RowState(text: "Looking\u{2026}", color: .orange)
        case .unpaired: return RowState(text: "Not paired", color: .gray)
        }
    }
    private func photos(_ s: HubState) -> RowState {
        if !s.settings.photos { return RowState(text: "Off", color: .gray) }
        if s.link != .connected { return RowState(text: "Paused", color: .gray) }
        if s.features.photos == .needsPermission { return RowState(text: "Needs permission", color: .orange) }
        return RowState(text: s.photoSyncing ? "Syncing\u{2026}" : "Up to date", color: .green)
    }
    private func notifications(_ s: HubState) -> RowState {
        if !s.settings.notifications { return RowState(text: "Off", color: .gray) }
        if s.link != .connected { return RowState(text: "Paused", color: .gray) }
        if s.features.notifications == .needsPermission { return RowState(text: "Needs permission", color: .orange) }
        return RowState(text: "On", color: .green)
    }
}

extension URL {
    var abbreviatingHome: String { (path as NSString).abbreviatingWithTildeInPath }
}

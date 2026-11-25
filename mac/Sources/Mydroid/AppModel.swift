import SwiftUI
import AppKit
import ServiceManagement
import MydroidCore

enum SetupStep: Int, CaseIterable { case scan, confirm, choose, done }

enum ReplyStatus: Equatable { case sending, sent, failed(String) }

enum MainSection: String, CaseIterable, Identifiable {
    case messages, photos, calls, files
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .messages: return "message"
        case .photos: return "photo.on.rectangle"
        case .calls: return "phone"
        case .files: return "folder"
        }
    }
}

/// The UI-facing model. Owns the Hub, mirrors its state onto the main actor and wires the
/// platform pieces (notifications, clipboard, call panel, login item, sleep/wake).
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let hub: Hub
    private(set) var state = HubState()
    var setupStep: SetupStep = .scan
    @ObservationIgnored let ui = NotifUIState()
    var replyStatus: [String: ReplyStatus] {
        get { ui.replyStatus }
        set { ui.replyStatus = newValue }
    }
    /// Copy one-time codes the moment they arrive (Mac-only setting, off by default).
    var autoCopyCodes: Bool = false {
        didSet { defaults.set(autoCopyCodes, forKey: "autoCopyCodes") }
    }
    /// Mac-only preferences (Settings window).
    var prefs = MacPrefs() {
        didSet { prefs.save(defaults); applyPrefs() }
    }
    /// Which Mac folders the phone can browse in Android's Files app (Settings > Files).
    var fileShare = FileShareSettings(roots: []) {
        didSet { if fileShare != oldValue { saveFileShare(); applyFileShare() } }
    }
    /// Every app the phone has sent a notification for (Settings > Notifications).
    private(set) var knownApps = KnownApps()
    var bluetooth: BluetoothStatus = .unknown
    var blePresenceActive = false
    /// Whether the "follow Focus" option can work for this build. Hidden when it can't.
    var focusAvailable = false
    var photosAccessNote: String?
    var previewPhoto: SavedFile?
    var findingPhone = false
    var toast: String?
    var launchAtLogin = false
    var loginItemNote: String?
    var photosDirectory: URL
    var answeredCalls: Set<String> = []
    /// Calls whose floating panel the user closed. The call keeps going; the popover shows it instead.
    var hiddenCalls: Set<String> = []

    func hideCallPanel() {
        guard let c = state.call else { return }
        hiddenCalls.insert(c.callId)
        callPanel.sync(call: c)
    }

    func showCallPanel() {
        guard let c = state.call else { return }
        hiddenCalls.remove(c.callId)
        callPanel.sync(call: c)
    }
    var fixRequestedAt: [FixKind: Date] = [:]

    // The full window (Messages, Photos, Calls, Files).
    let messages: MessagesModel
    let photos: PhotosModel
    let calls: CallsModel
    let files: FilesModel
    /// Mac call audio (PROTOCOL.md 8): setup, adb, the helper and the audio engine.
    let callAudio: CallAudioController
    // v1.5: Remote (10), quick actions and Mac status (11), walk-away lock (12).
    let remote: RemoteController
    let ring: RingController
    let walkAway: WalkAwayController
    // v1.7: authenticator (PROTOCOL.md 14): the shortcut and its HUD, the browser helper's socket, and the extension install rows.
    let authShortcut: AuthShortcutController
    let extensionInstaller: ExtensionInstaller
    @ObservationIgnored let otpService: OTPSocketService
    /// The system refused the chosen shortcut (another app has it).
    var authShortcutConflict = false
    @ObservationIgnored private var registeredAuthKey: AuthShortcutKey?
    @ObservationIgnored private var hotKeysLive = true
    @ObservationIgnored let macStatus: MacStatusMonitor
    @ObservationIgnored let macActions: MacActionService
    var section: MainSection = .messages
    private(set) var mainWindowOpen = false
    @ObservationIgnored private var pendingReplyKeys: Set<String> = []

    @ObservationIgnored let defaults: UserDefaults
    /// The Mac's name, as it shows on the phone (Quick Share and Files).
    @ObservationIgnored let macName: String
    @ObservationIgnored private let support: URL
    @ObservationIgnored let ble = BlePresence()
    @ObservationIgnored let focus = FocusMonitor()
    @ObservationIgnored private var lowBattery = LowBatteryTracker()
    @ObservationIgnored private var knownAppsSave: Task<Void, Never>?
    @ObservationIgnored var openWindowAction: ((String) -> Void)?
    @ObservationIgnored weak var menuBarWindow: NSWindow?
    @ObservationIgnored let notifier = Notifier()
    /// Opens URLs and Mac apps. Replaced by a recorder in tests.
    @ObservationIgnored var opener: MacOpener = WorkspaceOpener()
    /// Spotify for Mac (Continue on Mac, PROTOCOL.md 15). Replaced by a recorder in tests.
    @ObservationIgnored var spotify: SpotifyPlaying = SystemSpotify()
    /// The one-time Automation note for Spotify. Replaced in tests.
    @ObservationIgnored var explainSpotify: () async -> Bool = { SpotifyExplainer.confirm() }
    /// The camera for importing from Google Authenticator (PROTOCOL.md 14.4). Replaced in tests.
    @ObservationIgnored var makeCamera: () -> CameraSource = { SystemCamera() }
    /// The open camera-import window's controller; nil when the window is closed.
    var cameraImport: CameraImportController?
    /// Keys of `notif.open` requests waiting for the phone's `notif.result`.
    @ObservationIgnored private var pendingOpenKeys: [String: Date] = [:]
    @ObservationIgnored let clipboard = ClipboardMonitor()
    @ObservationIgnored let thumbnails = QuickLookThumbnails()
    @ObservationIgnored let spotlight = SpotlightSearch()
    @ObservationIgnored let callPanel = CallPanelController()
    @ObservationIgnored private let networkWatcher = NetworkWatcher()
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var lastLink: LinkState = .unpaired

    static let defaultCaches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Mydroid", isDirectory: true)

    static let defaultPhotosDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures/Mydroid", isDirectory: true)

    private init() {
        let env = ProcessInfo.processInfo.environment
        let identityStore: KeyValueStore
        let config: KeyValueStore
        let support: URL
        let defaults = UserDefaults.standard
        self.defaults = defaults
        let macName = Host.current().localizedName ?? "Mac"
        self.macName = macName
        var photos = AppModel.defaultPhotosDirectory
        var caches = AppModel.defaultCaches
        var downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        if let dev = env["MYDROID_DATA_DIR"] {
            // Developer/test mode: nothing touches the Keychain, ~/Pictures or ~/Downloads.
            let root = URL(fileURLWithPath: dev, isDirectory: true)
            identityStore = FileKeyValueStore(directory: root.appendingPathComponent("state"))
            config = identityStore
            support = root
            photos = root.appendingPathComponent("Pictures", isDirectory: true)
            downloads = root.appendingPathComponent("Downloads", isDirectory: true)
            caches = root.appendingPathComponent("Caches", isDirectory: true)
        } else {
            config = UserDefaultsKeyValueStore()
            support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Mydroid", isDirectory: true)
            // Keychain for team-signed builds; a private file for local builds (no password prompt per rebuild).
            identityStore = SecretStorage.make(service: "com.mydroid.mac", supportDirectory: support)
            if let p = defaults.string(forKey: "photosPath") { photos = URL(fileURLWithPath: p, isDirectory: true) }
        }
        photosDirectory = photos
        self.support = support
        hub = Hub(HubConfiguration(
            macName: macName,
            identity: Identity(store: identityStore), config: config,
            ledgerURL: support.appendingPathComponent("ledger.json"),
            photosDirectory: photos, downloadsDirectory: downloads,
            libraryDirectory: caches.appendingPathComponent("Library", isDirectory: true)))
        messages = MessagesModel(hub: hub, support: support)
        self.photos = PhotosModel(hub: hub, caches: caches)
        calls = CallsModel(hub: hub)
        files = FilesModel(hub: hub, support: support)
        let adb = AdbClient(home: support.appendingPathComponent("adb-home", isDirectory: true))
        let developerAdb = AdbClient(port: 5037, home: support, existingServer: true)
        callAudio = CallAudioController(adb: adb, developerAdb: developerAdb, engine: CallAudioEngine(), defaults: defaults)
        let ring = RingController()
        self.ring = ring
        let remote = RemoteController(hub: hub)
        self.remote = remote
        // The quick actions get their own poster (the lock chord), separate from the pointer stream's.
        let actions = MacActionService(accessibility: remote.checker, poster: CGEventPoster(), runner: ProcessCommandRunner(), ring: ring)
        macActions = actions
        let status = MacStatusMonitor(name: macName)
        macStatus = status
        walkAway = WalkAwayController(scanner: CBScanner(), idle: HIDIdleTime(), waker: UserActivityWaker(),
                                      actions: { actions }, isLocked: { [unowned status] in status.locked })
        otpService = OTPSocketService(broker: hub.auth)
        extensionInstaller = ExtensionInstaller()
        authShortcut = AuthShortcutController(
            broker: hub.auth, browsers: SystemFrontBrowser(), typer: CGEventCodeTyper(), accessibility: remote.checker,
            hud: AuthHUDPanelController(),
            openAccessibility: { remote.openAccessibilitySettings() },
            openAutomation: { SystemFrontBrowser.openAutomationSettings() })
        attachModels()
        if env["MYDROID_LOG"] != nil { hub.log = { FileHandle.standardError.write(Data("[mydroid] \($0)\n".utf8)) } }
        state = hub.snapshot
        lastLink = state.link
        launchAtLogin = SMAppService.mainApp.status == .enabled
        autoCopyCodes = defaults.bool(forKey: "autoCopyCodes")
        prefs = MacPrefs.load(defaults)
        knownApps = Self.loadKnownApps(support)
        applyPrefs()
        hub.setScreenshotsSubfolder(prefs.screenshotsInSubfolder)
        fileShare = Self.loadFileShare(defaults, developerRoot: env["MYDROID_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) })
        hub.setFileShareProviders(thumbnails: thumbnails, search: spotlight)
        applyFileShare()

        hub.onState = { s in DispatchQueue.main.async { MainActor.assumeIsolated { AppModel.shared.apply(s) } } }
        hub.onEvent = { e in DispatchQueue.main.async { MainActor.assumeIsolated { AppModel.shared.handle(e) } } }
        ui.reply = { [weak self] n, t in self?.reply(to: n, text: t) }
        ui.dismiss = { [weak self] n in self?.dismiss(n) }
        ui.perform = { [weak self] n, i in self?.hub.performAction(key: n.key, index: i) }
        ui.copyCode = { [weak self] n in self?.copyCode(n) }
        ui.opened = { [weak self] n in self?.messages.markRead(key: n.key, canReply: n.canReply) }
        ui.closed = { [weak self] n in self?.messages.flushRead(n.key) }
        ui.quickShareRespond = { [weak self] id, accept in self?.quickShareRespond(id: id, accept: accept) }
        wireOpening()
        notifier.model = self
        notifier.prepare()
        callPanel.model = self
        ble.onChange = { [weak self] in self?.syncBluetooth() }
        ble.sync(uuid: state.bleUUID)
        syncBluetooth()
        focusAvailable = focus.available
        wireCallAudio()
        // The phone must hear what the Mac remembers (settings.callAudio), e.g. after a reset of the Hub's saved settings.
        if callAudio.enabled != state.settings.callAudio { updateSettings { $0.callAudio = callAudio.enabled } }
        hub.macActions = actions
        let workspace = AppKitWorkspace()
        let scripts = OsascriptRunner()
        hub.macRemote = MacRemoteService(
            workspace: workspace,
            present: PresentService(workspace: workspace, scripts: scripts, poster: CGEventPoster(), publish: { [weak hub] in hub?.setPresentState($0) }),
            media: MediaService(workspace: workspace, scripts: scripts, artwork: AppKitArtwork(), publish: { [weak hub] in hub?.setMacMedia($0) }))
        remote.start(hub: hub)
        status.onChange = { [weak self] in self?.hub.setMacStatus($0) }
        status.start()
        syncWalkAway()
        hub.start()
        callAudio.start()
        wireAuthenticator()
        otpService.start()
        GlobalHotKey.shared.register { AppModel.shared.openMainWindow() }
        syncAuthShortcut()
        observeSystem()
        networkWatcher.start { [weak self] in
            Task { @MainActor in
                self?.hub.restartListener(dropConnections: false)
                // The phone's wireless-debugging address and port can change with the network.
                self?.callAudio.linkChanged(connected: self?.state.link == .connected)
            }
        }
    }

    /// A model with fixture state and no networking, for off-screen renders and tests.
    init(fixture s: HubState, knownApps: KnownApps = KnownApps(), prefs: MacPrefs = MacPrefs(), fileShare: FileShareSettings? = nil) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mydroid-fixture-\(UUID().uuidString)", isDirectory: true)
        let store = FileKeyValueStore(directory: dir)
        defaults = UserDefaults(suiteName: "mydroid.fixture.\(UUID().uuidString)")!
        macName = "MacBook Pro"
        support = dir
        let pictures = dir.appendingPathComponent("Pictures/Mydroid", isDirectory: true)
        photosDirectory = pictures
        hub = Hub(HubConfiguration(macName: "Mac", identity: Identity(store: store), config: store,
                                   ledgerURL: dir.appendingPathComponent("ledger.json"),
                                   photosDirectory: pictures, downloadsDirectory: dir.appendingPathComponent("Downloads"),
                                   advertiseBonjour: false))
        state = s
        self.knownApps = knownApps
        self.prefs = prefs
        self.fileShare = fileShare ?? FileShareSettings.standard(
            desktop: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"),
            documents: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents"),
            downloads: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
        focusAvailable = true
        messages = MessagesModel(hub: hub, support: dir)
        messages.smsEnabled = s.settings.smsHistory         // the fixture's settings are what the views should show
        photos = PhotosModel(hub: hub, caches: dir.appendingPathComponent("Caches", isDirectory: true))
        calls = CallsModel(hub: hub)
        files = FilesModel(hub: hub, support: dir)
        callAudio = CallAudioController(adb: StubAdb(), engine: NullAudioEngine(), defaults: defaults)
        ring = RingController(sound: NullRingSound(), volume: NullVolume(), panel: NullRingPanel(), waker: NullWaker())
        remote = RemoteController(hub: hub, live: false)
        macActions = MacActionService(accessibility: remote.checker, poster: NullPoster(), runner: ProcessCommandRunner(), ring: ring)
        macStatus = MacStatusMonitor(name: "MacBook Pro")
        walkAway = WalkAwayController(scanner: NullScanner(), idle: NullIdle(), waker: NullWaker(), actions: { nil }, isLocked: { false })
        hotKeysLive = false
        otpService = OTPSocketService(broker: hub.auth)
        extensionInstaller = ExtensionInstaller(home: dir.appendingPathComponent("home", isDirectory: true),
                                                hostPath: "/Applications/Mydroid.app/Contents/MacOS/mydroid-nmhost", extensionFolder: nil,
                                                defaults: defaults)
        authShortcut = AuthShortcutController(broker: hub.auth, browsers: NullFrontBrowser(), typer: NullTyper(),
                                              accessibility: FakeTrust(), hud: NullHUD(), openAccessibility: {}, openAutomation: {})
        notifier.model = self
        wireOpening()
        attachModels()
        wireCallAudio()
        wireAuthenticator()
    }

    /// Connects the shortcut controller and the browser helper's socket to the preferences.
    private func wireAuthenticator() {
        authShortcut.hooks = AuthShortcutController.Hooks(
            automationExplained: { [weak self] in self?.prefs.authAutomationExplained ?? true },
            setAutomationExplained: { [weak self] in self?.prefs.authAutomationExplained = true })
        otpService.updateSites(prefs.authAutofillSites)
        otpService.log = { [weak self] m in self?.hub.log(m) }
        otpService.onExtensionHello = { [weak self] b in self?.extensionInstaller.markSeen(b) }
        otpService.onAutofillChanged = { [weak self] domain, on in
            guard let self else { return }
            var sites = self.prefs.authAutofillSites
            if on, !sites.contains(domain) { sites.append(domain); sites.sort() }
            if !on { sites.removeAll { $0 == domain } }
            if sites != self.prefs.authAutofillSites { self.prefs.authAutofillSites = sites }
        }
    }

    /// Registers the code shortcut (default Control-Option-C), or removes it when turned off.
    func syncAuthShortcut() {
        guard hotKeysLive else { return }
        if prefs.authShortcutEnabled {
            guard registeredAuthKey != prefs.authShortcut else { return }
            let ok = HotKeyCenter.shared.register(id: 2, keyCode: prefs.authShortcut.keyCode, modifiers: prefs.authShortcut.modifiers) {
                AppModel.shared.authShortcut.trigger()
            }
            registeredAuthKey = ok ? prefs.authShortcut : nil
            authShortcutConflict = !ok
        } else {
            HotKeyCenter.shared.unregister(id: 2)
            registeredAuthKey = nil
            authShortcutConflict = false
        }
    }

    /// Clicks, right-click menu entries and the per-app "When clicked" choice (PROTOCOL.md 13).
    private func wireOpening() {
        ui.clickBehavior = { [weak self] pkg in self?.prefs.clickBehavior(for: pkg) ?? .default }
        ui.open = { [weak self] n in self?.open(n) }
        ui.openOnPhone = { [weak self] n in self?.openOnPhone(n) }
        ui.openOnWeb = { [weak self] n in self?.openOnWeb(n) }
        ui.search = { [weak self] n in self?.searchWeb(n) }
        ui.copyText = { [weak self] n in self?.copyText(n) }
        ui.mute = { [weak self] n in self?.mute(n) }
    }

    private func attachModels() {
        messages.app = self; photos.app = self; calls.app = self; files.app = self
    }

    /// Connects the call-audio controller to the Hub and the UI. Needs `self`, so it runs after initialisation.
    private func wireCallAudio() {
        callAudio.hooks = CallAudioHooks(
            linkConnected: { [weak self] in self?.state.link == .connected },
            phoneName: { [weak self] in self?.state.phone?.name ?? "phone" },
            phoneHost: { [weak self] in self?.state.phoneHost },
            wirelessDebugging: { [weak self] in self?.state.features.wirelessDebugging },
            openDevOptions: { [weak self] in self?.hub.fix(.devoptions) },
            sendVerify: { [weak self] nonce in self?.hub.sendAdbVerify(nonce: nonce) },
            setPhoneSetting: { [weak self] on in self?.updateSettings { $0.callAudio = on } },
            answeredOnMac: { [weak self] id in self?.answeredCalls.contains(id) ?? false },
            flash: { [weak self] text in self?.flash(text) },
            log: { [weak self] m in self?.hub.log("callaudio: \(m)") })
        callAudio.onLayoutChange = { [weak self] in
            guard let self else { return }
            self.callPanel.sync(call: self.state.call)
        }
    }

    private static func loadKnownApps(_ support: URL) -> KnownApps {
        guard let d = try? Data(contentsOf: support.appendingPathComponent("knownapps.json")),
              let k = try? JSONDecoder().decode(KnownApps.self, from: d) else { return KnownApps() }
        return k
    }

    private func saveKnownApps() {
        knownAppsSave?.cancel()
        let snapshot = knownApps
        let url = support.appendingPathComponent("knownapps.json")
        knownAppsSave = Task.detached {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: url, options: .atomic) }
        }
    }

    private func applyPrefs() {
        OneTimeCode.lifetime = TimeInterval(prefs.codeCardMinutes * 60)
        hub.setScreenshotsSubfolder(prefs.screenshotsInSubfolder)
        hub.setQuickShare(prefs.quickShare)
        remote.apply(prefs: prefs)
        syncWalkAway()
        otpService.updateSites(prefs.authAutofillSites)
        syncAuthShortcut()
    }

    /// Scans for the phone only while the toggle is on, a phone is paired and Bluetooth can be used.
    func syncWalkAway() {
        walkAway.configure(enabled: state.settings.walkAway && isPaired, phoneUUID: state.phoneBleUUID,
                           sensitivity: prefs.walkAwaySensitivity, wakeOnReturn: prefs.walkAwayWake)
    }

    func setWalkAway(_ on: Bool) { updateSettings { $0.walkAway = on } }

    // MARK: Mac files on the phone (PROTOCOL.md section 9)

    private static let fileShareKey = "fileShareSettings"

    /// Desktop, Documents and Downloads unless the user changed the list. In developer mode the defaults are folders under the data
    /// directory, so nothing touches the real home folder (and no privacy prompts appear).
    private static func loadFileShare(_ defaults: UserDefaults, developerRoot: URL?) -> FileShareSettings {
        if let d = defaults.data(forKey: fileShareKey), let s = try? JSONDecoder().decode(FileShareSettings.self, from: d) { return s }
        let fm = FileManager.default
        if let dev = developerRoot {
            return .standard(desktop: dev.appendingPathComponent("Desktop"), documents: dev.appendingPathComponent("Documents"),
                             downloads: dev.appendingPathComponent("Downloads"))
        }
        func dir(_ d: FileManager.SearchPathDirectory, _ name: String) -> URL {
            fm.urls(for: d, in: .userDomainMask).first ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(name)
        }
        return .standard(desktop: dir(.desktopDirectory, "Desktop"), documents: dir(.documentDirectory, "Documents"), downloads: dir(.downloadsDirectory, "Downloads"))
    }

    private func saveFileShare() {
        if let d = try? JSONEncoder().encode(fileShare) { defaults.set(d, forKey: Self.fileShareKey) }
    }

    /// Resolves the folders (following any that moved) and gives the Hub the list.
    func applyFileShare() {
        let r = fileShare.resolved()
        hub.setFileShare(r.config)
        if let updated = r.updated { fileShare = updated }     // refreshed bookmarks; this runs applyFileShare once more with the same result
    }

    func setFileShareEnabled(_ on: Bool) { fileShare.enabled = on }

    func setShareWritable(_ id: String, _ on: Bool) {
        guard let i = fileShare.roots.firstIndex(where: { $0.id == id }) else { return }
        fileShare.roots[i].writable = on
    }

    func removeShareFolder(_ id: String) { fileShare.roots.removeAll { $0.id == id } }

    func addShareFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = false
        p.allowsMultipleSelection = true
        p.prompt = "Share"
        p.message = "Choose folders to show in \(phoneName)'s Files app"
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK else { return }
        var s = fileShare
        for u in p.urls { s.add(u) }
        fileShare = s
    }

    func quickShareRespond(id: String, accept: Bool) {
        hub.quickShareRespond(id: id, accept: accept)
        notifier.retractQuickShare(id: id)
    }

    private static func preview(of text: String) -> String {
        let one = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return one.count > 70 ? String(one.prefix(70)) + "\u{2026}" : one
    }

    private func syncBluetooth() {
        bluetooth = ble.status
        blePresenceActive = ble.advertising
    }

    /// Banners are held back during quiet hours and (best effort) while a Focus is on. The list keeps everything.
    var bannersSuppressed: Bool {
        prefs.quietHours.contains(Date()) || (prefs.followFocus && focus.isFocused)
    }

    // MARK: Derived

    var phoneName: String { state.phone?.name ?? "your phone" }
    var isPaired: Bool { state.link != .unpaired }

    enum MenuIcon { case connected, searching, attention, idle }
    var menuIcon: MenuIcon {
        switch state.link {
        case .unpaired: return .idle
        case .searching: return .searching
        case .connected: return state.fixes.isEmpty ? .connected : .attention
        }
    }

    // MARK: Hub -> UI

    private func apply(_ s: HubState) {
        let old = state
        state = s
        if s.link != lastLink {
            lastLink = s.link
            if s.link != .connected { findingPhone = false; clipboard.stop() }
            callAudio.linkChanged(connected: s.link == .connected)
            if s.link == .unpaired { callAudio.phoneUnpaired() }
        }
        if setupStep == .scan, s.pairing?.confirmCode != nil { setupStep = .confirm; bringSetupToFront() }
        if setupStep == .confirm, s.pairing?.confirmCode == nil, s.link != .connected { setupStep = .scan }
        if s.settings.clipboard && s.link == .connected { startClipboard() } else { clipboard.stop() }
        if old.call != s.call {
            callAudio.callChanged(old: old.call, new: s.call)
            callPanel.sync(call: s.call)
        }
        if s.bleUUID != old.bleUUID { ble.sync(uuid: s.bleUUID); syncBluetooth() }
        if s.settings.walkAway != old.settings.walkAway || s.phoneBleUUID != old.phoneBleUUID || s.link != old.link { syncWalkAway() }
        if s.link == .connected, s.phone?.battery != old.phone?.battery || s.phone?.charging != old.phone?.charging || old.link != .connected {
            checkLowBattery(s)
        }
        if s.settings.notifications != old.settings.notifications, s.settings.notifications { Task { await notifier.requestAuthorization() } }
        messages.update(notifications: s.notifications.items, smsEnabled: s.settings.smsHistory, connected: s.link == .connected)
        files.sync(transfers: s.transfers)
        if s.bleUUID != old.bleUUID { photos.setPairing(s.bleUUID) }
        if old.call?.phase != .ended, s.call?.phase == .ended { calls.callEnded() }
    }

    private func checkLowBattery(_ s: HubState) {
        guard let p = s.phone else { return }
        if lowBattery.update(battery: p.battery, charging: p.charging), let b = p.battery, !bannersSuppressed {
            notifier.showLowBattery(title: "\(p.name) battery at \(b)%",
                                    detail: p.lowPowerMode ? "Battery saver is on" : "Plug it in soon")
        }
    }

    func handle(_ e: HubEvent) {
        messages.handle(e); photos.handle(e); calls.handle(e); files.handle(e)
        switch e {
        case let .notificationPosted(n, isNew):
            if knownApps.note(n) { saveKnownApps() }
            if isNew && state.settings.notifications && !state.settings.mutedApps.contains(n.pkg) && !bannersSuppressed {
                var copied = false
                if n.hasActiveCode(), autoCopyCodes { copied = copyCode(n) }
                notifier.show(n, autoCopied: copied)
            }
        case let .linkOpen(url):
            if prefs.linksOpenAutomatically { NSWorkspace.shared.open(url) } else { notifier.showLink(url, from: phoneName) }
        case let .received(f):
            if f.kind == "photo", prefs.importToApplePhotos { Task { await PhotosImporter.add(f.url) } }
        case .sessionReady:
            applyFileShare()                         // a shared folder may have been moved since the last time
        case .sessionClosed:
            remote.sessionEnded()                    // let go of a drag, hide the laser
        case .remoteAsk:
            remote.permissionNeeded(explicit: true)
            hub.resendRemoteState()
        case let .quickShareRequest(r):
            notifier.showQuickShareRequest(r)
        case let .quickShareRequestEnded(id):
            notifier.retractQuickShare(id: id)
        case let .quickShareText(text, from):
            clipboard.writeRemote(text)                  // marked as our own write, so clipboard sync won't send it back
            notifier.showCopied(from: from, preview: Self.preview(of: text))
        case let .quickShareLink(url, from):
            if prefs.linksOpenAutomatically { NSWorkspace.shared.open(url) } else { notifier.showLink(url, from: from) }
        case let .quickShareDone(d):
            notifier.showSaved(d)
        case let .quickShareFailed(from, reason):
            flash("Couldn't receive from \(from): \(reason)")
        case let .notificationRemoved(key):
            notifier.retract(key: key)
        case let .notificationResult(key, ok, error):
            // `notif.result` answers replies, button presses and `notif.open` alike. An open has no reply field to update.
            if pendingOpenKeys[key] != nil, !pendingReplyKeys.contains(key) {
                phoneOpenResult(key: key, ok: ok)
                return
            }
            replyStatus[key] = ok ? .sent : .failed(error ?? "The phone couldn't send it")
            if ok { Task { try? await Task.sleep(for: .seconds(2)); replyStatus[key] = nil } }
            if pendingReplyKeys.remove(key) != nil {
                // Replying counts as reading (PROTOCOL.md 7.6), and only now: reading removes the notification.
                messages.replyResult(key: key, ok: ok, error: error)
                if ok { messages.replySucceeded(key: key) }
            }
        case let .clipboard(text):
            clipboard.writeRemote(text)
        case let .sent(_, name, skipped):
            flash(skipped ? "\(name) is already on \(phoneName)" : "Sent \(name) to \(phoneName)")
        case let .sendFailed(_, name, error):
            flash("Couldn't send \(name)"); hub.log("send failed: \(error)")
        case .unpaired:
            setupStep = .scan
            openSetup()
        default: break
        }
    }

    func flash(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { withAnimation(.spring(duration: 0.35)) { toast = nil } }
        }
    }

    // MARK: Actions

    func reply(to n: PhoneNotification, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        replyStatus[n.key] = .sending
        pendingReplyKeys.insert(n.key)
        hub.reply(key: n.key, text: t)
        // No answer from the phone in 8s: say so instead of hanging.
        Task {
            try? await Task.sleep(for: .seconds(8))
            if replyStatus[n.key] == .sending { replyStatus[n.key] = .failed("No answer from your phone") }
        }
    }

    func dismiss(_ n: PhoneNotification) {
        hub.dismiss(key: n.key)
        notifier.retract(key: n.key)
    }

    /// Puts the code on the clipboard (marked so clipboard sync never sends it to the phone).
    @discardableResult
    func copyCode(_ n: PhoneNotification) -> Bool {
        guard let code = n.otp?.code else { return false }
        clipboard.writeSecret(code)
        ui.copiedKey = n.key
        let key = n.key
        Task { try? await Task.sleep(for: .seconds(3)); if ui.copiedKey == key { ui.copiedKey = nil } }
        return true
    }

    func dismissAll() { for n in state.notifications.items { dismiss(n) } }

    /// Changes the synced settings and sends them to the phone.
    func updateSettings(_ change: (inout SyncSettings) -> Void) {
        var s = state.settings
        change(&s)
        guard s != state.settings else { return }
        state.settings = s
        hub.setSettings(s)
        syncWalkAway()          // the toggle is local state first; the Hub's echo would see no difference
    }

    func isMuted(_ pkg: String) -> Bool { state.settings.mutedApps.contains(pkg) }

    func setMuted(_ pkg: String, _ muted: Bool) {
        updateSettings { s in
            s.mutedApps.removeAll { $0 == pkg }
            if muted { s.mutedApps.append(pkg) }
        }
    }

    /// "Mute app" from a notification row or banner.
    func mute(_ n: PhoneNotification) {
        guard !n.pkg.isEmpty else { return }
        _ = knownApps.note(n); saveKnownApps()
        setMuted(n.pkg, true)
        notifier.retract(key: n.key)
        flash("Muted \(n.displayApp)")
    }

    // MARK: Opening notifications (PROTOCOL.md 13)

    /// What a plain click does for this notification, under the user's choice for its app.
    func clickAction(for n: PhoneNotification) -> OpenAction { ui.clickAction(n) }

    /// A click on a row, banner or system notification: do the default for that app.
    func open(_ n: PhoneNotification) { perform(clickAction(for: n), for: n) }

    func openOnPhone(_ n: PhoneNotification) { perform(.phone(key: n.key), for: n) }

    func openOnWeb(_ n: PhoneNotification) {
        guard let url = ui.router.plan(for: n).web else { return }
        perform(.web(url), for: n)
    }

    func searchWeb(_ n: PhoneNotification) {
        guard let url = OpenRouter.searchURL(for: n) else { return }
        Task { _ = await opener.open(url) }
    }

    /// The notification's text, for "Copy text". Marked so clipboard sync never echoes it to the phone.
    func copyText(_ n: PhoneNotification) {
        var lines: [String] = []
        if let c = n.effectiveConversation, !c.messages.isEmpty {
            lines = c.messages.map { ($0.isMine || $0.sender.isEmpty ? "" : "\($0.sender): ") + $0.text }
        } else {
            lines = [n.title, n.text].filter { !$0.isEmpty }
        }
        let text = lines.joined(separator: "\n")
        guard !text.isEmpty else { return }
        clipboard.writeSecret(text)
        flash("Copied")
    }

    /// Whether this notification is a conversation, so that opening it counts as reading it (PROTOCOL.md 7.6).
    private func isConversation(_ n: PhoneNotification) -> Bool { n.isMessage || n.conversation != nil }

    func perform(_ action: OpenAction, for n: PhoneNotification) {
        switch action {
        case .none:
            break
        case let .phone(key):
            guard state.link == .connected else { flash("\(phoneName) isn't connected"); return }
            pendingOpenKeys[key] = Date()
            hub.openOnPhone(key: key)
            flash("Opening on your phone")
            // No answer from the phone: forget the request (the phone shows its own "Tap to open" if it couldn't launch).
            Task {
                try? await Task.sleep(for: .seconds(15))
                pendingOpenKeys[key] = nil
            }
        case let .web(url):
            Task {
                if await opener.open(url) { openedOnMac(n) } else { flash("Couldn't open the page") }
            }
        case let .macApp(bundleID, url, fallback):
            Task {
                if await opener.open(url, bundleID: bundleID) { openedOnMac(n); return }
                // The app wouldn't take it: the web page does the same job.
                if let fallback, await opener.open(fallback) { openedOnMac(n) } else { flash("Couldn't open the page") }
            }
        }
    }

    private func openedOnMac(_ n: PhoneNotification) {
        if isConversation(n), state.notifications.items.contains(where: { $0.key == n.key }) { messages.readElsewhere(key: n.key) }
    }

    private func phoneOpenResult(key: String, ok: Bool) {
        pendingOpenKeys[key] = nil
        guard ok else { flash("Couldn't open it on your phone"); return }
        if let n = state.notifications.items.first(where: { $0.key == key }), isConversation(n) { messages.readElsewhere(key: key) }
    }

    /// A system notification was clicked (its default action).
    func openNotification(key: String) {
        guard let n = state.notifications.items.first(where: { $0.key == key }) else { return }
        open(n)
    }

    /// The "When clicked" setting for an app, with what each choice does.
    func setClickBehavior(_ b: ClickBehavior, for pkg: String) { prefs.setClickBehavior(b, for: pkg) }

    func setImportToApplePhotos(_ on: Bool) {
        guard on else { prefs.importToApplePhotos = false; photosAccessNote = nil; return }
        Task {
            let ok = await PhotosImporter.requestAccess()
            prefs.importToApplePhotos = ok
            photosAccessNote = ok ? nil : (PhotosImporter.available
                ? "Allow access in System Settings \u{203A} Privacy & Security \u{203A} Photos"
                : "Not available in this build")
        }
    }

    func setFollowFocus(_ on: Bool) {
        guard on else { prefs.followFocus = false; return }
        Task {
            let ok = await focus.request()
            prefs.followFocus = ok
            focusAvailable = focus.available
        }
    }

    func openBluetoothSettings() {
        let url = bluetooth == .unauthorized ? "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
                                             : "x-apple.systempreferences:com.apple.BluetoothSettings"
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    var bluetoothSummary: (text: String, ok: Bool) {
        guard isPaired else { return ("Not paired", false) }
        switch bluetooth {
        case .on: return blePresenceActive ? ("Visible to your phone", true) : ("Starting\u{2026}", false)
        case .off: return ("Off", false)
        case .unauthorized: return ("Needs permission", false)
        case .unsupported: return ("Not available", false)
        case .unknown: return ("Checking\u{2026}", false)
        }
    }

    func mediaCommand(_ action: String) { hub.mediaCommand(action) }

    /// "Continue on Mac" or "Search on web" on the Now Playing row (PROTOCOL.md 15).
    func continueOnMac(_ media: MediaState) {
        let handoff = MediaHandoff(spotify: spotify, opener: opener, pausePhone: prefs.pausePhoneOnContinue,
                                   explained: prefs.spotifyAutomationExplained,
                                   markExplained: { [weak self] in self?.prefs.spotifyAutomationExplained = true },
                                   explain: explainSpotify,
                                   sendPause: { [weak self] in self?.mediaCommand("pause") })
        Task { @MainActor [weak self] in
            let result = await handoff.run(media)
            self?.flash(result.message)
        }
    }

    // MARK: Import from Google Authenticator (PROTOCOL.md 14.4)

    /// Opens the camera window. A second call while it is open just brings it forward.
    func openCameraImport() {
        if cameraImport == nil {
            cameraImport = CameraImportController(camera: makeCamera(), importer: hub.auth, phoneConnected: state.link == .connected)
        }
        openWindowAction?("authimport")
    }

    /// The window closed: camera off, everything read is forgotten.
    func closeCameraImport() {
        cameraImport?.stop()
        cameraImport = nil
    }

    /// Send text, a link or files to the phone (Services menu, `mydroid://send`, drops).
    func send(_ payload: SendPayload) {
        guard state.link == .connected else { flash("\(phoneName) isn't connected"); return }
        switch payload {
        case let .files(urls):
            let files = urls.filter { u in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) && !isDir.boolValue
            }
            guard !files.isEmpty else { flash("Couldn't find a file to send"); return }
            sendFiles(files)
        case let .link(u):
            flash(hub.sendLink(u) ? "Link sent to \(phoneName)" : "Couldn't send the link")
        case let .text(t):
            flash(hub.sendText(t) ? "Text sent to \(phoneName)" : "Couldn't send the text")
        }
    }

    func setSetting(_ key: WritableKeyPath<SyncSettings, Bool>, _ value: Bool) {
        updateSettings { $0[keyPath: key] = value }
        if value, key == \.clipboard { startClipboard() }
        if !value, key == \.clipboard { clipboard.stop() }
    }

    func toggleFind() {
        findingPhone.toggle()
        if findingPhone { hub.findPhone() } else { hub.stopFindingPhone() }
    }

    func fix(_ kind: FixKind) {
        fixRequestedAt[kind] = Date()
        hub.fix(kind)
    }

    func sendFiles(_ urls: [URL]) {
        files.send(urls)
    }

    func chooseFilesToSend() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.message = "Choose files to send to \(phoneName)"
        p.prompt = "Send"
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK { sendFiles(p.urls) }
    }

    func choosePhotosFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.directoryURL = photosDirectory
        p.prompt = "Choose"
        p.message = "Where should photos from \(phoneName) be saved?"
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url { setPhotosDirectory(u) }
    }

    func setPhotosDirectory(_ u: URL) {
        photosDirectory = u
        UserDefaults.standard.set(u.path, forKey: "photosPath")
        hub.setPhotosDirectory(u)
    }

    var photosFolderLabel: String {
        let pictures = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures").path
        if photosDirectory.path.hasPrefix(pictures) { return "Pictures" }
        return photosDirectory.lastPathComponent
    }

    func unpair() {
        lowBattery.reset()
        hub.unpair()
        notifier.retractAll()
        callPanel.sync(call: nil)
    }

    // MARK: Setup flow

    func beginSetup() {
        setupStep = .scan
        hub.startPairing()
    }

    func codesMatch() {
        hub.confirmPairing()
        withAnimation(.spring(duration: 0.5, bounce: 0.2)) { setupStep = .choose }
    }

    func scanAgain() {
        hub.rejectPairing()
        withAnimation(.spring(duration: 0.5, bounce: 0.2)) { setupStep = .scan }
    }

    func finishChoices() {
        // Launch at login is on by default after setup.
        setLaunchAtLogin(true)
        withAnimation(.spring(duration: 0.5, bounce: 0.2)) { setupStep = .done }
    }

    func closeSetup() {
        hub.cancelPairing()
        NSApp.windows.first { $0.identifier?.rawValue.contains("setup") == true }?.close()
    }

    func openSetup() {
        beginSetup()
        openWindowAction?("setup")
        bringSetupToFront()
    }

    func openSettings() { openWindowAction?("settings") }

    /// Settings opens on a given tab (the popover's call-audio card links to Calls).
    var settingsTab: SettingsTab = .general
    func openSettings(_ tab: SettingsTab) { settingsTab = tab; openWindowAction?("settings") }

    /// The guided "Hear calls on your Mac" sheet.
    func openCallAudioSetup() {
        closeMenuBarWindow()
        callAudio.beginSetup()
        openWindowAction?("callaudio")
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Main window

    /// "Open Mydroid": the full window, in the Dock and Cmd-Tab while it is open.
    func openMainWindow(_ section: MainSection? = nil) {
        if let section { self.section = section }
        closeMenuBarWindow()
        NSApp.setActivationPolicy(.regular)
        openWindowAction?("main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeMenuBarWindow() {
        if let menuBarWindow, menuBarWindow.isVisible { menuBarWindow.close() }
    }

    func mainWindowAppeared() {
        UIDiagnostics.start()
        mainWindowOpen = true
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func mainWindowDisappeared() {
        mainWindowOpen = false
        messages.windowClosed()
        messages.flushSave()
        NSApp.dockTile.badgeLabel = nil
        NSApp.setActivationPolicy(.accessory)
    }

    func updateDockBadge() {
        guard mainWindowOpen else { return }
        let n = messages.unreadCount
        NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    private func bringSetupToFront() { NSApp.activate(ignoringOtherApps: true) }

    // MARK: Platform

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemNote = nil
        } catch {
            loginItemNote = "macOS wouldn't change this: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func startClipboard() {
        clipboard.start { [weak self] text in self?.hub.sendClipboard(text) }
    }

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // The network takes a moment to come back after wake.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                self?.hub.restartListener(dropConnections: true)
                self?.applyFileShare()
                self?.ble.restart()
                self?.callAudio.linkChanged(connected: self?.state.link == .connected)
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ring.stop(); self?.callAudio.shutdown(); self?.hub.stop() }
        }
    }
}

/// Polls the pasteboard while the clipboard feature is on and sends changes to the phone.
@MainActor
final class ClipboardMonitor {
    private var timer: Timer?
    private var lastChange = NSPasteboard.general.changeCount
    private var guardState = ClipboardGuard()
    private var onLocal: ((String) -> Void)?

    func start(onLocal: @escaping (String) -> Void) {
        self.onLocal = onLocal
        guard timer == nil else { return }
        lastChange = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// Copies something sensitive (a verification code). Flagged concealed and remembered as our own
    /// write, so it is neither shown by clipboard managers nor echoed to the phone.
    func writeSecret(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        pb.setString(text, forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        lastChange = pb.changeCount
        guardState.remoteArrived(text)
    }

    func writeRemote(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastChange = pb.changeCount          // our own write is not a local change
        guardState.remoteArrived(text)
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        let types = pb.types?.map(\.rawValue) ?? []
        // Password managers mark secrets; never forward those.
        if ClipboardGuard.isSensitive(types: types) { return }
        guard let text = pb.string(forType: .string), let out = guardState.localChanged(text) else { return }
        onLocal?(out)
    }
}


/// A fixed Accessibility answer for fixtures.
final class FakeTrust: AccessibilityChecking {
    var isTrusted = true
}

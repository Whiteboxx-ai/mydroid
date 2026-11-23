import Foundation
import AppKit
import MydroidCore
import MydroidNM

/// Answers the browser extension (through `mydroid-nmhost`) on `otp.sock`. Requests go to `OTPBridge`, which asks the phone through the Hub's `AuthBroker`.
/// The per-site auto-fill list lives in `MacPrefs`; this keeps a thread-safe copy for the socket threads.
final class OTPSocketService: OTPBridgeHost, @unchecked Sendable {
    private let lock = NSLock()
    private var sites: Set<String> = []
    private let broker: AuthBroker
    private var server: OTPSocketServer?
    private var bridge: OTPBridge?
    /// Called on the main actor when the extension turns auto-fill on or off for a site.
    var onAutofillChanged: (@MainActor (String, Bool) -> Void)?
    /// Called on the main actor when the extension says hello from a browser (setup watches for it).
    var onExtensionHello: (@MainActor (ChromiumBrowser) -> Void)?
    var log: (String) -> Void = { _ in }
    private(set) var listening = false

    init(broker: AuthBroker) { self.broker = broker }

    var phoneConnected: Bool { broker.isConnected }

    func updateSites(_ list: [String]) { lock.lock(); sites = Set(list); lock.unlock() }

    func autofillAllowed(domain: String) -> Bool { lock.lock(); defer { lock.unlock() }; return sites.contains(domain) }

    func setAutofill(domain: String, enabled: Bool) {
        lock.lock()
        if enabled { sites.insert(domain) } else { sites.remove(domain) }
        lock.unlock()
        let cb = onAutofillChanged
        Task { @MainActor in cb?(domain, enabled) }
    }

    func extensionHello(browser: String?, parent: String?) {
        let b = parent.flatMap { ChromiumBrowser.from(executablePath: $0) } ?? ChromiumBrowser.from(name: browser)
        guard let b else { return }
        let cb = onExtensionHello
        Task { @MainActor in cb?(b) }
    }

    func start(path: String = OTPSocket.defaultPath()) {
        let bridge = OTPBridge(broker: broker, host: self)
        self.bridge = bridge
        let server = OTPSocketServer(path: path, log: log) { line, reply in
            Task.detached {
                var out: [String: Any]
                if let req = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { out = await bridge.handle(req) }
                else { out = ["ok": false, "error": "bad_request"] }
                reply((try? JSONSerialization.data(withJSONObject: out)) ?? Data("{\"ok\":false}".utf8))
            }
        }
        do { try server.start(); self.server = server; listening = true }
        catch OTPSocket.Failure.inUse { log("otp socket: another Mydroid is already serving it") }
        catch { log("otp socket: could not start (\(error))") }
    }

    func stop() { server?.stop(); server = nil; listening = false }
}

/// Installs and removes the native messaging manifest for each Chromium browser, keeps the extension in its stable folder, and
/// remembers which browsers' extension has said hello (Settings > Authenticator and its setup sheet).
@MainActor @Observable
final class ExtensionInstaller {
    struct Row: Identifiable, Equatable {
        var browser: ChromiumBrowser
        var present: Bool
        var state: ManifestState
        /// The extension has started in this browser and reached the app.
        var seen: Bool
        var id: String { browser.rawValue }
        /// Ready to fill: connected and the extension is loaded.
        var ready: Bool { state == .installed && seen }
    }

    private(set) var rows: [Row] = []
    private(set) var lastError: String?
    /// When each browser's extension last said hello.
    private(set) var seenAt: [String: Date] = [:]
    let home: URL
    let hostPath: String
    /// The copy inside the app. nil when running from `swift run`.
    let bundledFolder: URL?
    private let applicationDirectories: [URL]
    @ObservationIgnored let defaults: UserDefaults
    static let seenKey = "extensionSeen"

    /// The real thing: this app's helper and the extension bundled next to it.
    convenience init() {
        let res = Bundle.main.resourceURL?.appendingPathComponent("extension", isDirectory: true)
        self.init(home: FileManager.default.homeDirectoryForCurrentUser,
                  hostPath: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/mydroid-nmhost").path,
                  extensionFolder: res.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
    }

    /// `extensionFolder` is the copy that ships inside the app; it is copied to `stableFolder` (under `home`) on every start.
    init(home: URL, hostPath: String, extensionFolder: URL?, applicationDirectories: [URL]? = nil, defaults: UserDefaults = .standard) {
        self.home = home; self.hostPath = hostPath; self.bundledFolder = extensionFolder; self.defaults = defaults
        self.applicationDirectories = applicationDirectories ?? ManifestInstaller.defaultApplicationDirectories(home: home)
        if let d = defaults.dictionary(forKey: Self.seenKey) as? [String: Double] { seenAt = d.mapValues { Date(timeIntervalSince1970: $0) } }
        syncExtensionFolder()
        refresh()
    }

    /// Whether the helper is really in the app (it isn't when running from `swift run`).
    var helperAvailable: Bool { FileManager.default.isExecutableFile(atPath: hostPath) }

    /// `~/Library/Application Support/Mydroid/Browser Extension/`: the folder a browser loads.
    var stableFolder: URL { ExtensionFolder.stableURL(home: home) }

    /// The folder to load, once it exists.
    var extensionFolder: URL? {
        FileManager.default.fileExists(atPath: stableFolder.appendingPathComponent("manifest.json").path) ? stableFolder : nil
    }

    /// Copies the bundled extension to the stable folder when it is missing or older.
    @discardableResult
    func syncExtensionFolder() -> ExtensionFolder.Outcome {
        do { return try ExtensionFolder.sync(bundled: bundledFolder, stable: stableFolder) }
        catch { lastError = "Couldn\u{2019}t copy the extension to its folder."; return .noSource }
    }

    func refresh() {
        rows = ChromiumBrowser.allCases.map {
            Row(browser: $0, present: ManifestInstaller.isInstalled($0, home: home, applicationDirectories: applicationDirectories),
                state: ManifestInstaller.state($0, home: home, hostPath: hostPath), seen: seenAt[$0.rawValue] != nil)
        }
    }

    func row(_ b: ChromiumBrowser) -> Row { rows.first { $0.browser == b } ?? Row(browser: b, present: false, state: .notInstalled, seen: false) }

    func install(_ b: ChromiumBrowser) {
        do { try ManifestInstaller.install(b, home: home, hostPath: hostPath); lastError = nil }
        catch { lastError = "Couldn\u{2019}t write the file for \(b.displayName)." }
        refresh()
    }

    func remove(_ b: ChromiumBrowser) {
        ManifestInstaller.remove(b, home: home)
        seenAt[b.rawValue] = nil
        saveSeen()
        refresh()
    }

    /// The extension in `b` reached the app.
    func markSeen(_ b: ChromiumBrowser, at date: Date = Date()) {
        seenAt[b.rawValue] = date
        saveSeen()
        refresh()
    }

    private func saveSeen() { defaults.set(seenAt.mapValues { $0.timeIntervalSince1970 }, forKey: Self.seenKey) }

    func revealExtensionFolder() {
        guard let f = extensionFolder else { return }
        // Selects the folder in its parent, so it is the highlighted thing in the window.
        NSWorkspace.shared.activateFileViewerSelecting([f])
    }

    /// Opens the browser's extensions page in that browser. false when the browser or the address couldn't be opened
    /// (some builds refuse `chrome://` addresses from outside), so the caller can offer the paste fallback.
    func openExtensionsPage(_ b: ChromiumBrowser) async -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b.bundleID) else { return false }
        let page = b.extensionsPage
        return await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", app.path, page]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return false }
            p.waitUntilExit()
            return p.terminationStatus == 0
        }.value
    }

    /// Brings the browser to the front without opening anything.
    func bringForward(_ b: ChromiumBrowser) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

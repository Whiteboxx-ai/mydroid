import Foundation

/// Chromium browsers that read native messaging manifests from `NativeMessagingHosts` (PROTOCOL.md 14.3).
public enum ChromiumBrowser: String, CaseIterable, Sendable, Identifiable {
    case chrome, edge, brave, arc
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .chrome: return "Chrome"
        case .edge: return "Edge"
        case .brave: return "Brave"
        case .arc: return "Arc"
        }
    }

    public var appName: String {
        switch self {
        case .chrome: return "Google Chrome.app"
        case .edge: return "Microsoft Edge.app"
        case .brave: return "Brave Browser.app"
        case .arc: return "Arc.app"
        }
    }

    public var bundleID: String {
        switch self {
        case .chrome: return "com.google.Chrome"
        case .edge: return "com.microsoft.edgemac"
        case .brave: return "com.brave.Browser"
        case .arc: return "company.thebrowser.Browser"
        }
    }

    /// The browser's folder inside `~/Library/Application Support`.
    var supportSubpath: String {
        switch self {
        case .chrome: return "Google/Chrome"
        case .edge: return "Microsoft Edge"
        case .brave: return "BraveSoftware/Brave-Browser"
        case .arc: return "Arc/User Data"
        }
    }

    public var extensionsPage: String {
        switch self {
        case .chrome: return "chrome://extensions"
        case .edge: return "edge://extensions"
        case .brave: return "brave://extensions"
        // Arc is Chromium underneath and opens chrome:// addresses; arc:// is not a page it understands.
        case .arc: return "chrome://extensions"
        }
    }

    /// The app's name without `.app` (what `open -a` takes).
    public var applicationName: String { String(appName.dropLast(4)) }

    /// Which browser a running program's path belongs to (`.../Google Chrome.app/Contents/MacOS/Google Chrome`).
    /// Beta, Dev and Canary builds count as their browser.
    public static func from(executablePath path: String) -> ChromiumBrowser? {
        if path.contains("/Arc.app/") { return .arc }
        if path.contains("/Microsoft Edge") { return .edge }
        if path.contains("/Brave Browser") { return .brave }
        if path.contains("/Google Chrome") { return .chrome }
        return nil
    }

    /// The short name the extension reports for itself ("Chrome", "Edge", "Brave").
    public static func from(name: String?) -> ChromiumBrowser? {
        switch name?.lowercased() {
        case "chrome", "google chrome": return .chrome
        case "edge", "microsoft edge": return .edge
        case "brave", "brave browser": return .brave
        case "arc": return .arc
        default: return nil
        }
    }

    public func supportDirectory(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support", isDirectory: true).appendingPathComponent(supportSubpath, isDirectory: true)
    }

    public func manifestDirectory(home: URL) -> URL {
        supportDirectory(home: home).appendingPathComponent("NativeMessagingHosts", isDirectory: true)
    }

    public func manifestURL(home: URL) -> URL {
        manifestDirectory(home: home).appendingPathComponent("\(NativeMessaging.hostName).json")
    }
}

public enum HostManifest {
    /// The manifest Chrome reads: the helper's absolute path and both Mydroid extension origins.
    public static func data(hostPath: String) -> Data {
        let obj: [String: Any] = [
            "name": NativeMessaging.hostName,
            "description": "Mydroid: 2FA codes from your phone",
            "path": hostPath,
            "type": "stdio",
            "allowed_origins": NativeMessaging.allowedOrigins,
        ]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }
}

public enum ManifestState: Equatable, Sendable {
    case notInstalled
    /// Written, and it points at this copy of the helper.
    case installed
    /// A manifest exists but points somewhere else (the app moved) or lists another origin.
    case outdated
}

/// Writes and reads `com.mydroid.otp.json` in a browser's `NativeMessagingHosts` folder. Everything takes a home directory so
/// tests never touch the real profile.
public enum ManifestInstaller {
    /// Whether the browser looks installed: its app is in an Applications folder, or it has a profile folder.
    public static func isInstalled(_ b: ChromiumBrowser, home: URL, applicationDirectories: [URL]) -> Bool {
        let fm = FileManager.default
        if applicationDirectories.contains(where: { fm.fileExists(atPath: $0.appendingPathComponent(b.appName).path) }) { return true }
        return fm.fileExists(atPath: b.supportDirectory(home: home).path)
    }

    public static func defaultApplicationDirectories(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true), home.appendingPathComponent("Applications", isDirectory: true)]
    }

    @discardableResult
    public static func install(_ b: ChromiumBrowser, home: URL, hostPath: String) throws -> URL {
        let dir = b.manifestDirectory(home: home)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = b.manifestURL(home: home)
        try HostManifest.data(hostPath: hostPath).write(to: url, options: .atomic)
        return url
    }

    public static func remove(_ b: ChromiumBrowser, home: URL) {
        try? FileManager.default.removeItem(at: b.manifestURL(home: home))
    }

    public static func state(_ b: ChromiumBrowser, home: URL, hostPath: String) -> ManifestState {
        guard let d = try? Data(contentsOf: b.manifestURL(home: home)) else { return .notInstalled }
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              o["name"] as? String == NativeMessaging.hostName else { return .outdated }
        let origins = o["allowed_origins"] as? [String] ?? []
        return o["path"] as? String == hostPath && origins == NativeMessaging.allowedOrigins ? .installed : .outdated
    }
}

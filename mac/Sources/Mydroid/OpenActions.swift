import AppKit
import MydroidCore

/// Everything that opens something on the Mac goes through this, so tests (and renders) never launch anything.
@MainActor
protocol MacOpener: AnyObject {
    /// Opens a web page or URL in its default app. True when it was handed over.
    func open(_ url: URL) async -> Bool
    /// Launches a specific app, optionally opening a URL.
    func open(_ url: URL?, bundleID: String) async -> Bool
}

/// "Is this Mac app installed?" for the router, answered by LaunchServices.
struct WorkspaceLocator: AppLocator {
    func isInstalled(bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
}

@MainActor
final class WorkspaceOpener: MacOpener {
    func open(_ url: URL) async -> Bool {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        return (try? await NSWorkspace.shared.open(url, configuration: cfg)) != nil
    }

    func open(_ url: URL?, bundleID: String) async -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        guard let url else { return (try? await NSWorkspace.shared.openApplication(at: app, configuration: cfg)) != nil }
        return (try? await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: cfg)) != nil
    }
}

/// An opener that records instead of opening. For tests and off-screen renders.
@MainActor
final class RecordingOpener: MacOpener {
    var opened: [(url: URL?, bundleID: String?)] = []
    /// Bundle IDs whose app "fails to launch".
    var failing: Set<String> = []
    var failWeb = false
    func open(_ url: URL) async -> Bool { opened.append((url, nil)); return !failWeb }
    func open(_ url: URL?, bundleID: String) async -> Bool {
        opened.append((url, bundleID))
        return !failing.contains(bundleID)
    }
}

/// One entry of the right-click menu on a notification row or banner.
struct NotifMenuEntry: Identifiable {
    enum Kind { case openOnPhone, openOnWeb, search, copyText, mute }
    var kind: Kind
    var title: String
    var symbol: String
    var id: String { title }
}

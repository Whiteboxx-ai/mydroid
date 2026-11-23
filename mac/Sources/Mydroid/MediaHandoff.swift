import AppKit
import MydroidCore

// PROTOCOL.md 15: "Continue on Mac" and "Search on web" on the Now Playing row.
// Spotify for Mac is driven with AppleScript (needs Automation permission for Spotify, explained once). Otherwise the item opens on
// open.spotify.com. Afterwards the phone is paused, unless the user turned that off. Nothing here logs a URI, an id or a title.

enum SpotifyResult: Equatable {
    case ok
    /// macOS Automation permission for Spotify is off (error -1743).
    case notAllowed
    case failed
}

/// Spotify for Mac, behind a protocol: tests never touch the real app (and never run AppleScript against it).
@MainActor
protocol SpotifyPlaying: AnyObject {
    var isInstalled: Bool { get }
    /// Runs a script built by `ContinueOnMac.spotifyScript`.
    func play(script: String) async -> SpotifyResult
}

@MainActor
final class SystemSpotify: SpotifyPlaying {
    var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: ContinueOnMac.spotifyBundleID) != nil }

    func play(script: String) async -> SpotifyResult {
        await launchIfNeeded()
        // The first run asks the user for permission and blocks until they answer, so it must not run on the main thread.
        return await Task.detached(priority: .userInitiated) { () -> SpotifyResult in
            var error: NSDictionary?
            guard NSAppleScript(source: script)?.executeAndReturnError(&error) != nil else {
                let code = (error?[NSAppleScript.errorNumber] as? Int) ?? 0
                return code == -1743 ? .notAllowed : .failed
            }
            return .ok
        }.value
    }

    /// A Spotify that isn't running can't take `play track` straight away: start it, wait until it is up, and give it a moment.
    private func launchIfNeeded() async {
        let id = ContinueOnMac.spotifyBundleID
        guard NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty,
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: cfg)
        for _ in 0..<40 where NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
            try? await Task.sleep(for: .milliseconds(200))
        }
        try? await Task.sleep(for: .milliseconds(1500))
    }
}

enum HandoffResult: Equatable {
    case playingInSpotify
    /// Opened on open.spotify.com (or the item's own link). `why` says what to tell the user when Spotify was the plan.
    case openedInBrowser(why: Fallback?)
    case searched
    /// Nothing could be opened.
    case failed

    enum Fallback: Equatable { case spotifyNotAllowed, spotifyFailed, declined }

    /// A short toast. No title, artist or id.
    var message: String {
        switch self {
        case .playingInSpotify: return "Playing in Spotify on this Mac"
        case .openedInBrowser(let why):
            switch why {
            case .spotifyNotAllowed?: return "Opened in your browser. Allow Spotify under Automation."
            case .spotifyFailed?: return "Spotify didn\u{2019}t respond. Opened in browser."
            default: return "Opened on your Mac"
            }
        case .searched: return "Searching the web"
        case .failed: return "Couldn\u{2019}t open that on this Mac"
        }
    }
}

/// One tap on the Now Playing row's button.
@MainActor
struct MediaHandoff {
    var spotify: SpotifyPlaying
    var opener: MacOpener
    /// "Pause my phone when continuing on Mac".
    var pausePhone: Bool
    /// True once the Automation explainer has been read.
    var explained: Bool
    var markExplained: () -> Void
    /// Shows the one-time explainer. False means the user chose the browser instead.
    var explain: () async -> Bool
    var sendPause: () -> Void
    var now: () -> Date = Date.init

    func run(_ media: MediaState) async -> HandoffResult {
        switch ContinueOnMac.offer(for: media) {
        case nil:
            return .failed
        case .searchWeb(let url)?:
            return await opener.open(url) ? .searched : .failed
        case .continueOnMac(let ref)?:
            let result = await continueOnMac(ref, media)
            if result != .failed, pausePhone { sendPause() }
            return result
        }
    }

    private func continueOnMac(_ ref: MediaRef, _ media: MediaState) async -> HandoffResult {
        if spotify.isInstalled, let uri = ref.spotifyURI {
            if !explained {
                guard await explain() else { return await browser(ref, why: .declined) }
                markExplained()
            }
            let seconds = ContinueOnMac.startSeconds(of: media, at: now())
            if let script = ContinueOnMac.spotifyScript(uri: uri, seconds: seconds) {
                switch await spotify.play(script: script) {
                case .ok: return .playingInSpotify
                case .notAllowed: return await browser(ref, why: .spotifyNotAllowed)
                case .failed: return await browser(ref, why: .spotifyFailed)
                }
            }
        }
        return await browser(ref, why: nil)
    }

    private func browser(_ ref: MediaRef, why: HandoffResult.Fallback?) async -> HandoffResult {
        await opener.open(ref.webURL) ? .openedInBrowser(why: why) : .failed
    }
}

@MainActor
enum SpotifyExplainer {
    /// "Mydroid will ask to control Spotify". True to go on, false to use the browser instead.
    static func confirm() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Play in Spotify on this Mac?"
        a.informativeText = "macOS will ask to let Mydroid control Spotify. Mydroid only tells it which song to play. Change this later in Privacy & Security \u{203A} Automation."
        a.addButton(withTitle: "Continue")
        a.addButton(withTitle: "Use Browser")
        return a.runModal() == .alertFirstButtonReturn
    }
}

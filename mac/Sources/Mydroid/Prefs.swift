import Foundation
import MydroidCore

/// Settings that only matter on the Mac. (What the phone must know lives in `SyncSettings`.)
struct MacPrefs: Codable, Equatable {
    var showBatteryInMenuBar = false
    /// Links from the phone: open in the browser right away (true) or show a banner with Open (false).
    var linksOpenAutomatically = false
    var followFocus = false
    var quietHours = QuietHours()
    /// How long a verification code stays on offer, in minutes.
    var codeCardMinutes = 10
    var importToApplePhotos = false
    var screenshotsInSubfolder = false
    /// Quick Share receiving (Settings > Quick Share).
    var quickShare = QuickShareSettings()
    /// Remote (Settings > Remote): the laser's colour, and flipping the scroll direction.
    var laserColor = LaserColor.red
    var reverseScroll = false
    /// Walk-away lock (Settings > Walk-away lock). The on/off switch itself is `SyncSettings.walkAway`, because the phone has to know.
    var walkAwaySensitivity = WalkAwaySensitivity.medium
    var walkAwayWake = true
    /// The one-time "needs Bluetooth on both devices" note has been read.
    var walkAwayNoteSeen = false
    /// What clicking a notification does, per Android package (Settings > Notifications > When clicked). Missing = Default.
    var clickBehavior: [String: ClickBehavior] = [:]
    /// Authenticator (Settings > Authenticator, PROTOCOL.md 14.3).
    var authShortcutEnabled = true
    var authShortcut = AuthShortcutKey.standard
    /// Sites (eTLD+1) where the browser extension may fill a code without a click. Each fill is still approved on the phone.
    var authAutofillSites: [String] = []
    /// The one-time "Mydroid will ask to read your browser's address" note has been read.
    var authAutomationExplained = false
    /// Continue on Mac (PROTOCOL.md 15): pause the phone once the song is playing on the Mac (Settings > Media).
    var pausePhoneOnContinue = true
    /// The one-time "Mydroid will ask to control Spotify" note has been read.
    var spotifyAutomationExplained = false

    static let key = "macPrefs"

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        showBatteryInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showBatteryInMenuBar) ?? false
        linksOpenAutomatically = try c.decodeIfPresent(Bool.self, forKey: .linksOpenAutomatically) ?? false
        followFocus = try c.decodeIfPresent(Bool.self, forKey: .followFocus) ?? false
        quietHours = try c.decodeIfPresent(QuietHours.self, forKey: .quietHours) ?? QuietHours()
        codeCardMinutes = try c.decodeIfPresent(Int.self, forKey: .codeCardMinutes) ?? 10
        importToApplePhotos = try c.decodeIfPresent(Bool.self, forKey: .importToApplePhotos) ?? false
        screenshotsInSubfolder = try c.decodeIfPresent(Bool.self, forKey: .screenshotsInSubfolder) ?? false
        quickShare = try c.decodeIfPresent(QuickShareSettings.self, forKey: .quickShare) ?? QuickShareSettings()
        laserColor = try c.decodeIfPresent(LaserColor.self, forKey: .laserColor) ?? .red
        reverseScroll = try c.decodeIfPresent(Bool.self, forKey: .reverseScroll) ?? false
        walkAwaySensitivity = try c.decodeIfPresent(WalkAwaySensitivity.self, forKey: .walkAwaySensitivity) ?? .medium
        walkAwayWake = try c.decodeIfPresent(Bool.self, forKey: .walkAwayWake) ?? true
        walkAwayNoteSeen = try c.decodeIfPresent(Bool.self, forKey: .walkAwayNoteSeen) ?? false
        authShortcutEnabled = try c.decodeIfPresent(Bool.self, forKey: .authShortcutEnabled) ?? true
        authShortcut = try c.decodeIfPresent(AuthShortcutKey.self, forKey: .authShortcut) ?? .standard
        authAutofillSites = try c.decodeIfPresent([String].self, forKey: .authAutofillSites) ?? []
        authAutomationExplained = try c.decodeIfPresent(Bool.self, forKey: .authAutomationExplained) ?? false
        pausePhoneOnContinue = try c.decodeIfPresent(Bool.self, forKey: .pausePhoneOnContinue) ?? true
        spotifyAutomationExplained = try c.decodeIfPresent(Bool.self, forKey: .spotifyAutomationExplained) ?? false
        // Tolerate a value this build doesn't know (a newer build wrote it): that app just goes back to Default.
        let raw = try c.decodeIfPresent([String: String].self, forKey: .clickBehavior) ?? [:]
        clickBehavior = raw.compactMapValues(ClickBehavior.init(rawValue:)).filter { $0.value != .default }
    }

    func clickBehavior(for pkg: String) -> ClickBehavior { clickBehavior[pkg] ?? .default }

    mutating func setClickBehavior(_ b: ClickBehavior, for pkg: String) {
        if b == .default { clickBehavior[pkg] = nil } else { clickBehavior[pkg] = b }
    }

    static func load(_ defaults: UserDefaults) -> MacPrefs {
        guard let d = defaults.data(forKey: key), let p = try? JSONDecoder().decode(MacPrefs.self, from: d) else { return MacPrefs() }
        return p
    }

    func save(_ defaults: UserDefaults) {
        if let d = try? JSONEncoder().encode(self) { defaults.set(d, forKey: Self.key) }
    }
}

enum BluetoothStatus: Equatable {
    case unknown, on, off, unauthorized, unsupported

    /// Bluetooth is a problem the user can fix.
    var needsAttention: Bool { self == .off || self == .unauthorized }
}

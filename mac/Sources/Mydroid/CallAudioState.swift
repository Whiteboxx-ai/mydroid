import Foundation
import MydroidCore

/// Everything about Mac call audio that survives a relaunch. Stored as one JSON blob in UserDefaults.
struct CallAudioPrefs: Codable, Equatable {
    /// The user finished setup and hasn't turned it off. Mirrors `settings.callAudio` on the phone.
    var enabled = false
    /// What the phone said it can do the last time we asked.
    var tier: CallAudioTier?
    /// "Not now" on the popover card. Permanent; Settings > Calls still offers it.
    var cardDismissed = false
    /// "Did the other person hear you?": nil = not answered yet.
    var talkConfirmed: Bool?
    /// A routed call has ended and the question hasn't been answered.
    var talkCheckPending = false
    /// Send the Mac's microphone into the call (full tier). Turned off when the answer was No.
    var talkEnabled = true
    /// "Use Mac audio when I answer on Mac"
    var routeOnAnswer = false
    var outputUID: String?
    var inputUID: String?
    var lastConnected: Date?
    /// The phone accepted the keep-alive grant (WRITE_SECURE_SETTINGS).
    var keepAliveGranted = false
    var lastHost: String?

    static let key = "callAudio"
    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        tier = try c.decodeIfPresent(CallAudioTier.self, forKey: .tier)
        cardDismissed = try c.decodeIfPresent(Bool.self, forKey: .cardDismissed) ?? false
        talkConfirmed = try c.decodeIfPresent(Bool.self, forKey: .talkConfirmed)
        talkCheckPending = try c.decodeIfPresent(Bool.self, forKey: .talkCheckPending) ?? false
        talkEnabled = try c.decodeIfPresent(Bool.self, forKey: .talkEnabled) ?? true
        routeOnAnswer = try c.decodeIfPresent(Bool.self, forKey: .routeOnAnswer) ?? false
        outputUID = try c.decodeIfPresent(String.self, forKey: .outputUID)
        inputUID = try c.decodeIfPresent(String.self, forKey: .inputUID)
        lastConnected = try c.decodeIfPresent(Date.self, forKey: .lastConnected)
        keepAliveGranted = try c.decodeIfPresent(Bool.self, forKey: .keepAliveGranted) ?? false
        lastHost = try c.decodeIfPresent(String.self, forKey: .lastHost)
    }

    static func load(_ defaults: UserDefaults) -> CallAudioPrefs {
        guard let d = defaults.data(forKey: key), let p = try? JSONDecoder().decode(CallAudioPrefs.self, from: d) else { return CallAudioPrefs() }
        return p
    }

    func save(_ defaults: UserDefaults) {
        if let d = try? JSONEncoder().encode(self) { defaults.set(d, forKey: Self.key) }
    }
}

/// How wireless debugging (adb over Wi-Fi) stands right now.
enum AdbLinkState: Equatable {
    case off              // call audio isn't turned on
    case searching        // waiting for the phone to be reachable
    case connected
    case unreachable      // the phone is there but wireless debugging isn't answering
}

enum RouteState: Equatable {
    case phone
    case mac
    case switching(to: AudioRoute)

    /// What the switch should show as selected.
    var shown: AudioRoute {
        switch self {
        case .phone: return .phone
        case .mac: return .mac
        case let .switching(to): return to
        }
    }
    var isSwitching: Bool { if case .switching = self { return true } else { return false } }
}

/// Smoothed 0...1 levels for the call panel meter. Levels only: audio is never kept.
@MainActor @Observable
final class AudioMeters {
    var rx: Float = 0
    var tx: Float = 0
    func reset() { rx = 0; tx = 0 }
}

// MARK: Setup flow

enum SetupStage: Equatable {
    case devOptions
    case wirelessDebugging
    case pairing
    case checking
    case result(CallAudioTier)
    case failed(item: Int, message: String)
}

enum SetupItemStatus: Equatable { case pending, active, done, failed }

struct SetupItem: Identifiable, Equatable {
    var id: Int
    var title: String
    var detail: String
    var status: SetupItemStatus
}

/// The guided sheet's live state. The checklist advances as the controller observes each step finish.
@MainActor @Observable
final class SetupProgress {
    var stage: SetupStage = .devOptions
    var detail = ""
    var hint: String?
    let service: String
    let password: String
    var phoneName: String

    init(service: String = AdbPairing.randomServiceName(), password: String = AdbPairing.randomPassword(), phoneName: String) {
        self.service = service; self.password = password; self.phoneName = phoneName
    }

    var qrPayload: String { AdbPairing.qrPayload(service: service, password: password) }

    var tier: CallAudioTier? { if case let .result(t) = stage { return t } else { return nil } }
    var failure: String? { if case let .failed(_, m) = stage { return m } else { return nil } }
    var isFinished: Bool { tier != nil }
    /// Show the QR before discovery so the user can scan as soon as Wireless debugging is on.
    var showsCode: Bool {
        switch stage {
        case .devOptions, .wirelessDebugging, .pairing: return true
        default: return false
        }
    }

    var activeIndex: Int {
        switch stage {
        case .devOptions: return 0
        case .wirelessDebugging: return 1
        case .pairing: return 2
        case .checking: return 3
        case .result: return 4
        case let .failed(item, _): return item
        }
    }

    var items: [SetupItem] {
        let failedAt: Int? = { if case let .failed(i, _) = stage { return i } else { return nil } }()
        func status(_ i: Int) -> SetupItemStatus {
            if let f = failedAt { return i < f ? .done : (i == f ? .failed : .pending) }
            return i < activeIndex ? .done : (i == activeIndex ? .active : .pending)
        }
        let tierText: String = {
            switch tier {
            case .some(.full): return "Hear and talk"
            case .some(.listen): return "Listen only"
            case .some(.none): return "Not possible on this phone"
            case nil: return "Checking\u{2026}"
            }
        }()
        return [
            SetupItem(id: 0, title: "Developer options",
                      detail: status(0) == .done ? "On" : (status(0) == .failed ? "Didn\u{2019}t finish" : "On your phone, turn on Wireless debugging."),
                      status: status(0)),
            SetupItem(id: 1, title: "Pair with a QR code",
                      detail: status(1) == .done ? "Scanned" : (status(1) == .failed ? "Didn\u{2019}t finish" : "Tap Pair device with QR code and scan."),
                      status: status(1)),
            SetupItem(id: 2, title: "Pairing",
                      detail: status(2) == .done ? "Paired and checked"
                          : status(2) == .failed ? "Didn\u{2019}t work"
                          : (detail.isEmpty ? "Automatic after scanning" : detail),
                      status: status(2)),
            SetupItem(id: 3, title: "Checking your phone",
                      detail: status(3) == .pending ? "" : (status(3) == .done ? tierText : (status(3) == .failed ? "Didn\u{2019}t answer" : "Checking\u{2026}")),
                      status: status(3)),
        ]
    }
}

/// Plain-language copy for each tier, shared by the setup result and Settings.
enum TierCopy {
    static func title(_ t: CallAudioTier) -> String {
        switch t {
        case .full: return "Hear and talk on your Mac"
        case .listen: return "Listen on your Mac"
        case .none: return "Not possible on this phone"
        }
    }

    static func detail(_ t: CallAudioTier) -> String {
        switch t {
        case .full:
            return "Switch between Phone and Mac in the call panel. Talking is experimental."
        case .listen:
            return "Hear the call on your Mac. Keep talking into your phone."
        case .none:
            return "You can still answer, decline and mute from your Mac."
        }
    }

    static func symbol(_ t: CallAudioTier) -> String {
        switch t {
        case .full: return "phone.arrow.up.right.circle.fill"
        case .listen: return "ear.fill"
        case .none: return "phone.down.circle.fill"
        }
    }
}

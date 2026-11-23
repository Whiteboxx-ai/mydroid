import Foundation

// PROTOCOL.md section 12: walk-away lock. The Mac scans for the phone's BLE advert and decides, from smoothed RSSI, whether you left.
// This file is the decision only. It touches no Bluetooth, no lock and no clock, so it is tested with made-up samples and times.
// Mydroid never unlocks the Mac: the machine has no such output.

public enum WalkAwaySensitivity: String, Codable, CaseIterable, Sendable, Equatable {
    case near, medium, far

    /// Smoothed RSSI (dBm) below which the phone counts as away.
    public var threshold: Double {
        switch self {
        case .near: return -65
        case .medium: return -75
        case .far: return -85
        }
    }

    public var title: String { rawValue.capitalized }
}

public enum SignalLevel: String, Sendable, Equatable {
    case none, weak, medium, strong

    public var label: String {
        switch self {
        case .none: return "not seen"
        case .weak: return "weak"
        case .medium: return "medium"
        case .strong: return "strong"
        }
    }
}

public struct WalkAwayTuning: Equatable, Sendable {
    /// Weight of the newest sample in the moving average.
    public var smoothing = 0.3
    /// Below the threshold for this long means away.
    public var belowFor: TimeInterval = 8
    /// Not seen for this long means away.
    public var unseenFor: TimeInterval = 12
    /// Back means above threshold + this many dB...
    public var returnMargin = 8.0
    /// ...for this long.
    public var returnFor: TimeInterval = 3
    /// The Mac is in use if the last keyboard or pointer input was less than this many seconds ago.
    public var inUseWithin: TimeInterval = 20
    /// After a gap this long, the average starts over from the new sample instead of blending with an old one.
    public var reseedAfter: TimeInterval = 6
    public init() {}
}

public struct WalkAwayMachine: Sendable {
    public enum Phase: Equatable, Sendable { case waiting, near, away }
    public enum Action: Equatable, Sendable {
        /// Lock the screen and put the display to sleep.
        case lock
        /// The phone is back after we locked: wake the display (the lock screen still wants Touch ID or the password).
        case returned
    }

    public var tuning: WalkAwayTuning
    public var sensitivity: WalkAwaySensitivity

    public private(set) var phase: Phase = .waiting
    /// The moving average, in dBm. nil until the first sample.
    public private(set) var smoothed: Double?
    public private(set) var lastSeen: Date?
    private var belowSince: Date?
    private var aboveSince: Date?
    /// The phone is away and we haven't acted yet (because the Mac is in use, or we haven't ticked since).
    private var lockPending = false
    /// We locked this time the phone went away, so its return should wake the display.
    private var didLock = false

    public init(sensitivity: WalkAwaySensitivity = .medium, tuning: WalkAwayTuning = WalkAwayTuning()) {
        self.sensitivity = sensitivity
        self.tuning = tuning
    }

    /// Back to "never seen" (feature turned off, Mac woke from sleep, pairing changed).
    public mutating func reset() {
        phase = .waiting; smoothed = nil; lastSeen = nil
        belowSince = nil; aboveSince = nil; lockPending = false; didLock = false
    }

    public var isLockPending: Bool { lockPending }

    /// A scan result. 127 (RSSI unavailable) and impossible values are ignored.
    public mutating func ingest(rssi: Int, at now: Date) {
        guard rssi < 0, rssi > -120 else { return }
        let v = Double(rssi)
        if let s = smoothed, let last = lastSeen, now.timeIntervalSince(last) <= tuning.reseedAfter {
            smoothed = tuning.smoothing * v + (1 - tuning.smoothing) * s
        } else {
            smoothed = v
            belowSince = nil; aboveSince = nil
        }
        lastSeen = now
        let t = sensitivity.threshold, avg = smoothed!
        if avg < t { if belowSince == nil { belowSince = now } } else { belowSince = nil }
        if avg > t + tuning.returnMargin { if aboveSince == nil { aboveSince = now } } else { aboveSince = nil }
        if phase == .waiting { phase = .near }
    }

    /// Call about once a second. `idle` is seconds since the last keyboard or pointer input (nil if unknown, which counts as idle).
    /// `screenLocked`: the screen is already locked, so there is nothing to do.
    public mutating func tick(now: Date, idle: TimeInterval?, screenLocked: Bool) -> Action? {
        guard let last = lastSeen else { return nil }
        let t = sensitivity.threshold

        if phase != .away {
            let below = belowSince.map { now.timeIntervalSince($0) >= tuning.belowFor } ?? false
            let unseen = now.timeIntervalSince(last) >= tuning.unseenFor
            if below || unseen {
                phase = .away
                lockPending = true
                didLock = false
                aboveSince = nil
            }
        }

        if phase == .away {
            if lockPending {
                if screenLocked {
                    lockPending = false                       // already locked by someone: nothing to lock, nothing to wake later
                } else if (idle ?? .infinity) >= tuning.inUseWithin {
                    lockPending = false
                    didLock = true
                    return .lock
                }                                              // else the Mac is in use: look again next tick
            }
            // Back: strongly above the threshold for a few seconds, and still being heard now.
            if let since = aboveSince, now.timeIntervalSince(since) >= tuning.returnFor,
               now.timeIntervalSince(last) < tuning.returnFor + 2, let avg = smoothed, avg > t + tuning.returnMargin {
                phase = .near
                lockPending = false
                belowSince = nil
                let wake = didLock
                didLock = false
                return wake ? .returned : nil
            }
        }
        return nil
    }

    /// For the meter in Settings.
    public func signal(now: Date) -> SignalLevel {
        guard let last = lastSeen, let avg = smoothed, now.timeIntervalSince(last) < tuning.unseenFor else { return .none }
        if avg >= -65 { return .strong }
        if avg >= -80 { return .medium }
        return .weak
    }

    /// 0...1 over -100...-45 dBm, for drawing the meter.
    public static func meterFraction(rssi: Double) -> Double { max(0, min(1, (rssi + 100) / 55)) }
}

import Foundation
import CoreGraphics

// PROTOCOL.md section 10: the phone as trackpad, keyboard, presenter and media remote.
// Everything here is pure or goes through `SyntheticEventPoster`, so tests never post a real event.

public enum MouseButton: String, Sendable, Equatable, CaseIterable {
    case left, right, middle
}

/// Modifier bits. The raw values are `CGEventFlags` (maskShift, maskControl, maskAlternate, maskCommand), so the real poster can copy them.
public struct ModifierFlags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static let shift = ModifierFlags(rawValue: 0x0002_0000)
    public static let control = ModifierFlags(rawValue: 0x0004_0000)
    public static let option = ModifierFlags(rawValue: 0x0008_0000)
    public static let command = ModifierFlags(rawValue: 0x0010_0000)

    /// `"cmd"`, `"shift"`, `"option"`, `"ctrl"` (a few aliases). Unknown names are ignored.
    public init(names: [String]) {
        var f: ModifierFlags = []
        for n in names {
            switch n.lowercased() {
            case "cmd", "command", "meta": f.insert(.command)
            case "shift": f.insert(.shift)
            case "option", "alt", "opt": f.insert(.option)
            case "ctrl", "control": f.insert(.control)
            default: break
            }
        }
        self = f
    }
}

/// System media keys (`NX_KEYTYPE_*`).
public enum MediaKey: Sendable, Equatable {
    case playPause, next, previous, volumeUp, volumeDown, mute

    public init?(action: String) {
        switch action {
        case "playpause": self = .playPause
        case "next": self = .next
        case "prev": self = .previous
        case "volup": self = .volumeUp
        case "voldown": self = .volumeDown
        case "mute": self = .mute
        default: return nil
        }
    }

    public var nxKeyType: Int {
        switch self {
        case .volumeUp: return 0
        case .volumeDown: return 1
        case .mute: return 7
        case .playPause: return 16
        case .next: return 17
        case .previous: return 18
        }
    }
}

public enum ScrollPhase: String, Sendable, Equatable {
    case began, changed, ended, momentum
}

/// One parsed `in.*` message.
public enum RemoteInput: Equatable, Sendable {
    case move(dx: Double, dy: Double)
    case scroll(dx: Double, dy: Double, phase: ScrollPhase?)
    case click(MouseButton, count: Int)
    case down(MouseButton)
    case up(MouseButton)
    case key(String, mods: ModifierFlags)
    case text(String)
    case media(MediaKey)
    /// `x` and `y` are 0...1 over the main display.
    case laser(on: Bool, x: Double, y: Double)

    /// Largest accepted pointer or scroll delta in one message. A hostile or buggy phone can't throw the cursor across the screen
    /// by more than this per message (the screen clamp does the rest).
    public static let maxDelta = 4000.0
    public static let maxTextLength = 4096

    public static func isInput(_ type: String) -> Bool { type.hasPrefix("in.") }

    public init?(message m: Message) {
        func button() -> MouseButton { m.string("button").flatMap(MouseButton.init(rawValue:)) ?? .left }
        func delta(_ k: String) -> Double { max(-Self.maxDelta, min(Self.maxDelta, m.double(k) ?? 0)) }
        switch m.type {
        case "in.move":
            self = .move(dx: delta("dx"), dy: delta("dy"))
        case "in.scroll":
            self = .scroll(dx: delta("dx"), dy: delta("dy"), phase: m.string("phase").flatMap(ScrollPhase.init(rawValue:)))
        case "in.click":
            let n = Int(m.int("count") ?? 1)
            self = .click(button(), count: max(1, min(3, n)))
        case "in.down": self = .down(button())
        case "in.up": self = .up(button())
        case "in.key":
            guard let key = m.string("key"), !key.isEmpty else { return nil }
            let mods = ModifierFlags(names: (m.fields["mods"] as? [String]) ?? [])
            guard KeyMap.plan(key: key, mods: mods) != nil else { return nil }
            self = .key(key, mods: mods)
        case "in.text":
            guard let t = m.string("text"), !t.isEmpty else { return nil }
            self = .text(t.count > Self.maxTextLength ? String(t.prefix(Self.maxTextLength)) : t)
        case "in.media":
            guard let k = m.string("action").flatMap(MediaKey.init(action:)) else { return nil }
            self = .media(k)
        case "in.laser":
            let on = m.bool("on") ?? false
            self = .laser(on: on, x: max(0, min(1, m.double("x") ?? 0.5)), y: max(0, min(1, m.double("y") ?? 0.5)))
        default:
            return nil
        }
    }
}

// MARK: Keys

/// Virtual keycode map for the key names the protocol lists (Carbon `kVK_*` values), and for printable characters on an ANSI layout.
public enum KeyMap {
    public static let named: [String: UInt16] = [
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        "enter": 0x24, "return": 0x24, "escape": 0x35, "esc": 0x35, "space": 0x31, "tab": 0x30,
        "backspace": 0x33, "delete": 0x75, "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
        "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
    ]

    /// Letters, digits and punctuation by physical position on an ANSI keyboard (`kVK_ANSI_*`).
    private static let ansi: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    public static func keyCode(named name: String) -> UInt16? { named[name.lowercased()] }

    public static func ansiKeyCode(for ch: Character) -> UInt16? {
        let l = ch.lowercased()
        return l.count == 1 ? ansi[l.first!] : nil
    }

    /// What to post for an `in.key`: a virtual keycode with modifier flags, or a Unicode character.
    public enum Plan: Equatable {
        case code(UInt16, ModifierFlags)
        case unicode(String, ModifierFlags)
    }

    /// Names go through the keycode map. A single character is typed as Unicode, except in a ctrl or cmd chord, where the key's position is
    /// what shortcuts match on (so cmd-c is the C key on every layout the ANSI map covers).
    public static func plan(key: String, mods: ModifierFlags) -> Plan? {
        if key.count > 1 {
            return keyCode(named: key).map { .code($0, mods) }
        }
        guard let ch = key.first else { return nil }
        switch ch {
        case "\n", "\r": return .code(0x24, mods)
        case "\t": return .code(0x30, mods)
        case " ": return .code(0x31, mods)
        default: break
        }
        let chord = !mods.isDisjoint(with: [.command, .control])
        if chord, let code = ansiKeyCode(for: ch) {
            var m = mods
            if ch.isUppercase { m.insert(.shift) }
            return .code(code, m)
        }
        guard ch.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { return nil }
        // Shift plus a lowercase letter types the capital, since Unicode text ignores the shift flag.
        if mods.contains(.shift), ch.isLowercase { return .unicode(String(ch).uppercased(), mods) }
        return .unicode(String(ch), mods)
    }
}

/// Splits typed text into pieces the keyboard can take: Unicode chunks (at most 20 UTF-16 units each, the practical `CGEvent` limit),
/// and Return and Tab as real keys.
public enum TextPlan {
    public enum Piece: Equatable { case chunk(String), newline, tab }
    public static let maxUnits = 20

    public static func pieces(_ text: String, maxUnits: Int = TextPlan.maxUnits) -> [Piece] {
        var out: [Piece] = []
        var cur = ""
        var units = 0
        func flush() { if !cur.isEmpty { out.append(.chunk(cur)); cur = ""; units = 0 } }
        for ch in text {
            if ch == "\n" || ch == "\r\n" || ch == "\r" { flush(); out.append(.newline); continue }
            if ch == "\t" { flush(); out.append(.tab); continue }
            let n = ch.utf16.count
            if n > maxUnits {
                // A cluster longer than a whole chunk: fall back to scalars so nothing is dropped.
                flush()
                for s in ch.unicodeScalars {
                    let u = String(s)
                    if units + u.utf16.count > maxUnits { flush() }
                    cur += u; units += u.utf16.count
                }
                continue
            }
            if units + n > maxUnits { flush() }
            cur.append(ch); units += n
        }
        flush()
        return out
    }
}

// MARK: Geometry

public enum ScreenGeometry {
    /// Keeps a point on one of the screens (global, top-left-origin coordinates). A point already on a screen is left alone,
    /// so the pointer moves freely across adjacent displays. Otherwise it goes to the nearest point of the nearest screen.
    public static func clamp(_ p: CGPoint, to rects: [CGRect]) -> CGPoint {
        guard !rects.isEmpty else { return p }
        if rects.contains(where: { $0.minX <= p.x && p.x < $0.maxX && $0.minY <= p.y && p.y < $0.maxY }) { return p }
        var best = p
        var bestDist = Double.infinity
        for r in rects {
            let q = CGPoint(x: min(max(p.x, r.minX), r.maxX - 1), y: min(max(p.y, r.minY), r.maxY - 1))
            let d = Double((q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y))
            if d < bestDist { bestDist = d; best = q }
        }
        return best
    }
}

// MARK: Posting

/// What the injector asks the system to do. The real poster turns these into `CGEvent`s; tests record them.
public enum SyntheticEvent: Equatable, Sendable {
    case mouseMove(CGPoint, dx: Double, dy: Double)
    case mouseDrag(CGPoint, MouseButton, dx: Double, dy: Double)
    case mouseButton(CGPoint, MouseButton, down: Bool, clickCount: Int)
    /// Pixel scroll. Phases use the raw `CGScrollPhase` and `CGMomentumScrollPhase` values (0 = none).
    case scroll(dx: Double, dy: Double, scrollPhase: Int, momentumPhase: Int)
    case key(code: UInt16, down: Bool, flags: ModifierFlags)
    /// A Unicode string typed as one key down and key up.
    case unicode(String, flags: ModifierFlags)
    case media(MediaKey, down: Bool)
}

public protocol SyntheticEventPoster: AnyObject {
    func post(_ event: SyntheticEvent)
    /// The pointer position now (global, top-left origin).
    func cursorLocation() -> CGPoint
    /// Every display, in the same coordinates.
    func screenFrames() -> [CGRect]
}

/// Turns `RemoteInput`s into synthetic events. Not thread-safe: feed it from one queue (`InputPipeline` does).
public final class InputInjector {
    private let poster: SyntheticEventPoster
    private let now: () -> Date
    /// Flips the scroll direction (Settings > Remote).
    public var reverseScroll = false

    private var position: CGPoint?
    private var lastMoveAt = Date.distantPast
    private var down: [MouseButton] = []
    private var inMomentum = false

    /// A tracked position is trusted for this long after our last move; after that the real pointer is read again (the user may have used the trackpad).
    public static let trackFor: TimeInterval = 0.4

    public init(poster: SyntheticEventPoster, now: @escaping () -> Date = Date.init) {
        self.poster = poster
        self.now = now
    }

    public var heldButtons: [MouseButton] { down }

    private func currentPosition() -> CGPoint {
        if let p = position, now().timeIntervalSince(lastMoveAt) < Self.trackFor { return p }
        return poster.cursorLocation()
    }

    public func handle(_ input: RemoteInput) {
        switch input {
        case let .move(dx, dy):
            let p0 = currentPosition()
            let p = ScreenGeometry.clamp(CGPoint(x: p0.x + dx, y: p0.y + dy), to: poster.screenFrames())
            position = p
            lastMoveAt = now()
            if let b = down.first {
                poster.post(.mouseDrag(p, b, dx: dx, dy: dy))
            } else {
                poster.post(.mouseMove(p, dx: dx, dy: dy))
            }
        case let .click(b, count):
            let p = currentPosition()
            for i in 1...max(1, count) {
                poster.post(.mouseButton(p, b, down: true, clickCount: i))
                poster.post(.mouseButton(p, b, down: false, clickCount: i))
            }
        case let .down(b):
            guard !down.contains(b) else { return }
            down.append(b)
            poster.post(.mouseButton(currentPosition(), b, down: true, clickCount: 1))
        case let .up(b):
            guard let i = down.firstIndex(of: b) else { return }
            down.remove(at: i)
            poster.post(.mouseButton(currentPosition(), b, down: false, clickCount: 1))
        case let .scroll(dx, dy, phase):
            scroll(dx: dx, dy: dy, phase: phase)
        case let .key(key, mods):
            guard let plan = KeyMap.plan(key: key, mods: mods) else { return }
            switch plan {
            case let .code(c, f):
                poster.post(.key(code: c, down: true, flags: f))
                poster.post(.key(code: c, down: false, flags: f))
            case let .unicode(s, f):
                poster.post(.unicode(s, flags: f))
            }
        case let .text(t):
            for piece in TextPlan.pieces(t) {
                switch piece {
                case let .chunk(s): poster.post(.unicode(s, flags: []))
                case .newline:
                    poster.post(.key(code: 0x24, down: true, flags: []))
                    poster.post(.key(code: 0x24, down: false, flags: []))
                case .tab:
                    poster.post(.key(code: 0x30, down: true, flags: []))
                    poster.post(.key(code: 0x30, down: false, flags: []))
                }
            }
        case let .media(k):
            poster.post(.media(k, down: true))
            poster.post(.media(k, down: false))
        case .laser:
            break       // not input: the laser overlay draws it
        }
    }

    private func scroll(dx: Double, dy: Double, phase: ScrollPhase?) {
        let sign = reverseScroll ? -1.0 : 1.0
        var scrollPhase = 0, momentum = 0
        switch phase {
        case nil: break
        case .began?: scrollPhase = 1; inMomentum = false
        case .changed?: scrollPhase = 2
        case .ended?:
            if inMomentum { momentum = 3; inMomentum = false } else { scrollPhase = 4 }
        case .momentum?:
            momentum = inMomentum ? 2 : 1
            inMomentum = true
        }
        poster.post(.scroll(dx: dx * sign, dy: dy * sign, scrollPhase: scrollPhase, momentumPhase: momentum))
    }

    /// Lets go of anything held (a drag in progress) and ends a scroll. Call when the session closes.
    public func releaseAll() {
        let p = currentPosition()
        for b in down { poster.post(.mouseButton(p, b, down: false, clickCount: 1)) }
        down.removeAll()
        if inMomentum { poster.post(.scroll(dx: 0, dy: 0, scrollPhase: 0, momentumPhase: 3)); inMomentum = false }
    }
}

/// Runs inputs on its own serial queue with as little delay as possible. Nothing waits for a timer: the first input goes straight
/// to the queue. If inputs arrive faster than they can be posted, neighbouring moves (and neighbouring scrolls in the same phase)
/// are added together, so the pointer lags by at most one batch instead of falling behind. Order is always kept.
public final class InputPipeline: @unchecked Sendable {
    private let queue: DispatchQueue
    private let handler: (RemoteInput) -> Void
    private let lock = NSLock()
    private var pending: [RemoteInput] = []
    private var draining = false
    private(set) var merged = 0

    public init(queue: DispatchQueue = DispatchQueue(label: "com.mydroid.input", qos: .userInteractive),
                handler: @escaping (RemoteInput) -> Void) {
        self.queue = queue
        self.handler = handler
    }

    /// Thread-safe.
    public func submit(_ input: RemoteInput) {
        lock.lock()
        if let last = pending.last, let m = Self.merge(last, input) {
            pending[pending.count - 1] = m
            merged += 1
            lock.unlock()
            return
        }
        pending.append(input)
        let start = !draining
        draining = true
        lock.unlock()
        if start { queue.async { [self] in drain() } }
    }

    /// Runs `block` on the input queue after everything submitted so far.
    public func perform(_ block: @escaping () -> Void) {
        queue.async(execute: block)
    }

    static func merge(_ a: RemoteInput, _ b: RemoteInput) -> RemoteInput? {
        switch (a, b) {
        case let (.move(x1, y1), .move(x2, y2)): return .move(dx: x1 + x2, dy: y1 + y2)
        case let (.scroll(x1, y1, p1), .scroll(x2, y2, p2)) where p1 == p2 && p1 != .began && p1 != .ended:
            return .scroll(dx: x1 + x2, dy: y1 + y2, phase: p1)
        default: return nil
        }
    }

    private func drain() {
        while true {
            lock.lock()
            let batch = pending
            pending.removeAll(keepingCapacity: true)
            if batch.isEmpty { draining = false; lock.unlock(); return }
            lock.unlock()
            for i in batch { handler(i) }
        }
    }
}

// MARK: Laser

/// Exponential smoothing for the laser dot, so a 60 Hz stream of points looks like a glide.
public struct LaserSmoother: Equatable, Sendable {
    public var current: CGPoint
    public var target: CGPoint
    /// Seconds for the dot to cover about two thirds of the remaining distance.
    public var tau: Double

    public init(start: CGPoint = CGPoint(x: 0.5, y: 0.5), tau: Double = 0.05) {
        current = start; target = start; self.tau = tau
    }

    public mutating func jump(to p: CGPoint) { current = p; target = p }

    @discardableResult
    public mutating func step(dt: Double) -> CGPoint {
        guard dt > 0 else { return current }
        let a = tau <= 0 ? 1 : 1 - exp(-dt / tau)
        current.x += (target.x - current.x) * a
        current.y += (target.y - current.y) * a
        return current
    }

    public var isSettled: Bool { abs(current.x - target.x) < 0.0005 && abs(current.y - target.y) < 0.0005 }
}

/// A shared latest-value mailbox (written from the network queue, read by the laser's frame timer).
public final class LaserMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = CGPoint(x: 0.5, y: 0.5)
    private var version = 0
    public init() {}
    public func set(x: Double, y: Double) { lock.lock(); value = CGPoint(x: x, y: y); version += 1; lock.unlock() }
    public func get() -> (point: CGPoint, version: Int) { lock.lock(); defer { lock.unlock() }; return (value, version) }
}

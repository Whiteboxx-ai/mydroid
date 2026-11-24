import AppKit
import ApplicationServices
import AudioToolbox
import CoreAudio
import CoreGraphics
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import MydroidCore

// The real system behind the Core protocols. Each piece is a thin mapping, so it can be swapped for a fake in tests.
// Nothing in the test suites constructs these.

// MARK: Accessibility

final class SystemAccessibility: AccessibilityChecking {
    /// `AXIsProcessTrusted` is the official answer. It has been seen to say no for an ad-hoc signed copy whose switch is on, so when it
    /// says no we also ask the question that matters: can this process post events? (An active event tap needs the same permission.)
    var isTrusted: Bool { AXIsProcessTrusted() || Self.canPostEvents() }

    private static func canPostEvents() -> Bool {
        let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                          callback: { _, _, event, _ in Unmanaged.passUnretained(event) }, userInfo: nil) else { return false }
        CFMachPortInvalidate(tap)
        return true
    }

    /// Adds Mydroid to the Accessibility list (the system sheet), and opens Privacy & Security > Accessibility.
    /// The first call per launch uses the prompt; later calls only open the pane.
    private var prompted = false
    func requestAndOpenSettings() {
        if !prompted {
            prompted = true
            // "AXTrustedCheckOptionPrompt" is the value of kAXTrustedCheckOptionPrompt.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        Self.openSettings()
    }

    /// For a permission that is switched on in System Settings but doesn't work: macOS ties it to one exact build of the app, and
    /// every rebuilt or updated copy counts as a new one. Clears Mydroid's entry, then asks again from scratch.
    func resetAndPrompt() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "com.mydroid.mac"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        prompted = false
        requestAndOpenSettings()
    }

    static func openSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(u) }
    }
}

// MARK: CGEvent poster

/// Posts synthetic events with `CGEvent` (and `NSEvent` for media keys). Needs Accessibility permission to have any effect.
/// Safe to call from any one queue at a time.
final class CGEventPoster: SyntheticEventPoster {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var remainderX = 0.0, remainderY = 0.0

    func cursorLocation() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    func screenFrames() -> [CGRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return [CGDisplayBounds(CGMainDisplayID())] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    func post(_ e: SyntheticEvent) {
        switch e {
        case let .mouseMove(p, dx, dy):
            mouse(.mouseMoved, p, .left, dx: dx, dy: dy)
        case let .mouseDrag(p, b, dx, dy):
            mouse(b == .left ? .leftMouseDragged : (b == .right ? .rightMouseDragged : .otherMouseDragged), p, b, dx: dx, dy: dy)
        case let .mouseButton(p, b, down, count):
            let type: CGEventType
            switch b {
            case .left: type = down ? .leftMouseDown : .leftMouseUp
            case .right: type = down ? .rightMouseDown : .rightMouseUp
            case .middle: type = down ? .otherMouseDown : .otherMouseUp
            }
            mouse(type, p, b, clickCount: count)
        case let .scroll(dx, dy, phase, momentum):
            scroll(dx: dx, dy: dy, phase: phase, momentum: momentum)
        case let .key(code, down, flags):
            guard let ev = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
            ev.flags = CGEventFlags(rawValue: flags.rawValue)
            ev.post(tap: .cghidEventTap)
        case let .unicode(text, flags):
            let units = Array(text.utf16)
            for down in [true, false] {
                guard let ev = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                ev.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                ev.flags = CGEventFlags(rawValue: flags.rawValue)
                ev.post(tap: .cghidEventTap)
            }
        case let .media(key, down):
            // NX_SYSDEFINED, subtype 8: data1 = (key << 16) | (state << 8), state 0xA down and 0xB up. The same number is the modifier word.
            let state = down ? 0xA00 : 0xB00
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state)),
                               timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                               data1: (key.nxKeyType << 16) | state, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private func mouse(_ type: CGEventType, _ p: CGPoint, _ b: MouseButton, dx: Double = 0, dy: Double = 0, clickCount: Int? = nil) {
        let button: CGMouseButton = b == .left ? .left : (b == .right ? .right : .center)
        guard let ev = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        if let clickCount { ev.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount)) }
        if type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged {
            ev.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
            ev.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        }
        ev.post(tap: .cghidEventTap)
    }

    /// Continuous pixel scroll. Fractions are carried to the next event so slow scrolling doesn't round to nothing.
    private func scroll(dx: Double, dy: Double, phase: Int, momentum: Int) {
        if phase == 1 { remainderX = 0; remainderY = 0 }        // a new gesture starts clean
        let x = dx + remainderX, y = dy + remainderY
        let ix = Int32(x.rounded(.towardZero)), iy = Int32(y.rounded(.towardZero))
        remainderX = x - Double(ix); remainderY = y - Double(iy)
        guard let ev = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: iy, wheel2: ix, wheel3: 0) else { return }
        ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        ev.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: y)
        ev.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: x)
        ev.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase))
        ev.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum))
        ev.post(tap: .cghidEventTap)
    }
}

// MARK: Output volume (for the ring)

protocol VolumeControlling: AnyObject {
    /// Raises the output volume to maximum and unmutes. Returns what to put back, or nil if the device has no volume control.
    func boost() -> VolumeSnapshot?
    func restore(_ snapshot: VolumeSnapshot)
}

struct VolumeSnapshot: Equatable { var volume: Float32; var muted: Bool }

final class SystemVolume: VolumeControlling {
    private func device() -> AudioObjectID? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private func get<T: BitwiseCopyable>(_ dev: AudioObjectID, _ selector: AudioObjectPropertySelector, _ zero: T) -> T? {
        var a = address(selector)
        guard AudioObjectHasProperty(dev, &a) else { return nil }
        var v = zero
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    private func set<T: BitwiseCopyable>(_ dev: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T) {
        var a = address(selector)
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(dev, &a), AudioObjectIsPropertySettable(dev, &a, &settable) == noErr, settable.boolValue else { return }
        var v = value
        _ = AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v)
    }

    func boost() -> VolumeSnapshot? {
        guard let dev = device() else { return nil }
        let main = AudioObjectPropertySelector(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard let vol: Float32 = get(dev, main, 0) else { return nil }
        let muted: UInt32 = get(dev, kAudioDevicePropertyMute, 0) ?? 0
        set(dev, kAudioDevicePropertyMute, UInt32(0))
        set(dev, main, Float32(1.0))
        return VolumeSnapshot(volume: vol, muted: muted != 0)
    }

    func restore(_ s: VolumeSnapshot) {
        guard let dev = device() else { return }
        set(dev, AudioObjectPropertySelector(kAudioHardwareServiceDeviceProperty_VirtualMainVolume), s.volume)
        set(dev, kAudioDevicePropertyMute, UInt32(s.muted ? 1 : 0))
    }
}

// MARK: Idle time, display wake

protocol IdleTimeSource: AnyObject {
    /// Seconds since the last keyboard or pointer input, or nil if it can't be read.
    func secondsSinceInput() -> TimeInterval?
}

/// `HIDIdleTime` from IOHIDSystem, in nanoseconds.
final class HIDIdleTime: IdleTimeSource {
    func secondsSinceInput() -> TimeInterval? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any],
              let ns = (dict["HIDIdleTime"] as? NSNumber)?.uint64Value else { return nil }
        return Double(ns) / 1_000_000_000
    }
}

protocol DisplayWaking: AnyObject {
    func wake()
}

/// Wakes the display the way a keypress would, without posting an input event. The lock screen still asks for Touch ID or a password.
final class UserActivityWaker: DisplayWaking {
    private var assertion = IOPMAssertionID(0)
    func wake() {
        let reason = "Mydroid: your phone is back" as CFString
        _ = IOPMAssertionDeclareUserActivity(reason, kIOPMUserActiveLocal, &assertion)
    }
}

// MARK: Mac status sources

enum MacInfo {
    static var model: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    /// The internal battery, if there is one: percentage and whether it is charging.
    static func battery() -> (percent: Int, charging: Bool)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
            return (Swift.min(100, Swift.max(0, cur * 100 / max)), charging)
        }
        return nil
    }

    /// `CGSSessionScreenIsLocked` from the current login session.
    static func screenLocked() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) ?? ((d["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false)
    }

    static func displayAsleep() -> Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }
}

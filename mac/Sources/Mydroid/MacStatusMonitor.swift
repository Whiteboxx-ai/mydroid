import AppKit
import IOKit.ps
import MydroidCore

/// Keeps `mac.status` current (PROTOCOL.md 11): battery from IOKit power sources, locked state from the login session,
/// display sleep from screen notifications. It reacts to change notifications only, never a timer; the Hub sends it on change only.
@MainActor
final class MacStatusMonitor {
    private(set) var status: MacStatus
    var onChange: (MacStatus) -> Void = { _ in }

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var powerSource: CFRunLoopSource?
    private var started = false

    init(name: String) {
        status = MacStatus(name: name, model: MacInfo.model)
    }

    var locked: Bool { status.locked }

    func start() {
        guard !started else { return }
        started = true
        // Power source changes (plugging in, each percent).
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<MacStatusMonitor>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { me.refresh() } }
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            powerSource = src
        }
        let ws = NSWorkspace.shared.notificationCenter
        add(ws, NSWorkspace.screensDidSleepNotification) { me in me.set { $0.displayAsleep = true } }
        add(ws, NSWorkspace.screensDidWakeNotification) { me in me.set { $0.displayAsleep = false } }
        add(ws, NSWorkspace.didWakeNotification) { me in me.refresh() }
        let dc = DistributedNotificationCenter.default()
        add(dc, Notification.Name("com.apple.screenIsLocked")) { me in me.set { $0.locked = true } }
        add(dc, Notification.Name("com.apple.screenIsUnlocked")) { me in me.set { $0.locked = false } }
        refresh()
        onChange(status)
    }

    private func add(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor (MacStatusMonitor) -> Void) {
        let o = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { body(self) } }
        }
        observers.append((center, o))
    }

    /// Reads everything again.
    func refresh() {
        set {
            if let b = MacInfo.battery() { $0.battery = b.percent; $0.charging = b.charging } else { $0.battery = nil; $0.charging = false }
            $0.locked = MacInfo.screenLocked()
            $0.displayAsleep = MacInfo.displayAsleep()
        }
    }

    private func set(_ change: (inout MacStatus) -> Void) {
        var s = status
        change(&s)
        guard s != status else { return }
        status = s
        onChange(s)
    }
}

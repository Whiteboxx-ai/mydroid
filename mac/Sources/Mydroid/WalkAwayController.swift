import AppKit
import CoreBluetooth
import MydroidCore

// PROTOCOL.md 12: walk-away lock on the Mac. The decision is `WalkAwayMachine` (Core, tested); this wires it to Bluetooth, the clock,
// the idle timer and the action layer. Mydroid never unlocks the Mac: there is no code path for it.

protocol BleScanning: AnyObject {
    var onSample: ((Int) -> Void)? { get set }
    var onState: ((BluetoothStatus) -> Void)? { get set }
    /// Scans for one service UUID, reporting every advertisement (duplicates allowed) while running.
    func start(serviceUUID: String)
    func stop()
}

/// CoreBluetooth central. Created only when walk-away is switched on (that is when Bluetooth access is first needed for scanning),
/// and scans with `allowDuplicates` only while the feature is on.
final class CBScanner: NSObject, BleScanning, CBCentralManagerDelegate {
    var onSample: ((Int) -> Void)?
    var onState: ((BluetoothStatus) -> Void)?
    private var manager: CBCentralManager?
    private var uuid: CBUUID?
    private var scanning = false

    private static var available: Bool { Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil }

    func start(serviceUUID: String) {
        guard Self.available, let u = UUID(uuidString: serviceUUID) else { return }
        uuid = CBUUID(nsuuid: u)
        if manager == nil { manager = CBCentralManager(delegate: self, queue: .main) }      // may show the Bluetooth permission prompt
        refresh()
    }

    func stop() {
        uuid = nil
        manager?.stopScan()
        scanning = false
    }

    private func refresh() {
        guard let m = manager else { return }
        switch m.state {
        case .poweredOn: onState?(.on)
        case .poweredOff: onState?(.off)
        case .unauthorized: onState?(.unauthorized)
        case .unsupported: onState?(.unsupported)
        default: onState?(.unknown)
        }
        if m.state == .poweredOn, let uuid, !scanning {
            m.scanForPeripherals(withServices: [uuid], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            scanning = true
        } else if (m.state != .poweredOn || uuid == nil), scanning {
            m.stopScan(); scanning = false
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        scanning = false                         // a power cycle ends any scan
        refresh()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let v = RSSI.intValue
        if v == 127 { return }                   // "RSSI not available"
        onSample?(v)
    }
}

@MainActor @Observable
final class WalkAwayController {
    /// The feature is on and scanning.
    private(set) var active = false
    private(set) var signal: SignalLevel = .none
    /// The smoothed signal in dBm, for the meter.
    private(set) var rssi: Double?
    private(set) var bluetooth: BluetoothStatus = .unknown
    private(set) var sensitivity: WalkAwaySensitivity = .medium
    private(set) var lockedCount = 0
    private(set) var lastLockAt: Date?

    @ObservationIgnored private var machine = WalkAwayMachine()
    @ObservationIgnored private let scanner: BleScanning
    @ObservationIgnored private let idle: IdleTimeSource
    @ObservationIgnored private let waker: DisplayWaking
    @ObservationIgnored private let actions: () -> MacActionPerforming?
    @ObservationIgnored private let isLocked: () -> Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var wakeOnReturn = true
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var uuid: String?

    init(scanner: BleScanning, idle: IdleTimeSource, waker: DisplayWaking, actions: @escaping () -> MacActionPerforming?,
         isLocked: @escaping () -> Bool, now: @escaping () -> Date = Date.init) {
        self.scanner = scanner; self.idle = idle; self.waker = waker; self.actions = actions; self.isLocked = isLocked; self.now = now
        scanner.onSample = { [weak self] rssi in MainActor.assumeIsolated { self?.sample(rssi) } }
        scanner.onState = { [weak self] s in MainActor.assumeIsolated { self?.bluetooth = s } }
    }

    /// Call whenever the toggle, the phone's UUID or the options change.
    func configure(enabled: Bool, phoneUUID: String?, sensitivity: WalkAwaySensitivity, wakeOnReturn: Bool) {
        self.sensitivity = sensitivity
        machine.sensitivity = sensitivity
        self.wakeOnReturn = wakeOnReturn
        let want = enabled && phoneUUID != nil
        if want, !active || uuid != phoneUUID {
            uuid = phoneUUID
            start(uuid: phoneUUID!)
        } else if !want, active {
            stop()
        }
    }

    private func start(uuid: String) {
        active = true
        machine.reset()
        scanner.start(serviceUUID: uuid)
        // An accessory app with no window can be napped by macOS, which would delay the timer and the scan callbacks.
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Walk-away lock")
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        // After the Mac wakes, the phone has to be heard again before anything can happen (a stale "last seen" must not lock a Mac you just opened).
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.machine.reset(); self?.publishMeter() }
            }
        }
    }

    private func stop() {
        active = false
        scanner.stop()
        timer?.invalidate(); timer = nil
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); wakeObserver = nil }
        machine.reset()
        uuid = nil
        signal = .none; rssi = nil
    }

    func sample(_ rssi: Int) {
        machine.ingest(rssi: rssi, at: now())
        publishMeter()
    }

    func tick() {
        let t = now()
        if let action = machine.tick(now: t, idle: idle.secondsSinceInput(), screenLocked: isLocked()) {
            switch action {
            case .lock: lockAndSleep()
            case .returned: if wakeOnReturn { waker.wake() }
            }
        }
        publishMeter()
    }

    private func publishMeter() {
        let s = machine.signal(now: now())
        if s != signal { signal = s }
        let r = machine.smoothed
        if r != rssi { rssi = r }
    }

    /// Lock, then put the display to sleep, both through the normal action layer (same as the phone's Lock and Display Sleep buttons).
    private func lockAndSleep() {
        guard let actions = actions() else { return }
        lockedCount += 1
        lastLockAt = now()
        actions.perform(.lock) { _ in
            // Give the lock a moment to take hold before the screen goes dark.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { actions.perform(.displaySleep) { _ in } }
        }
    }

    // MARK: Fixtures

    func setFixture(active: Bool, signal: SignalLevel, rssi: Double?, bluetooth: BluetoothStatus = .on) {
        self.active = active; self.signal = signal; self.rssi = rssi; self.bluetooth = bluetooth
    }
}

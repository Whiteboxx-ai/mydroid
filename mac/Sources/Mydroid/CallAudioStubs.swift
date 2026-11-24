import Foundation
import CoreGraphics
import MydroidCore

/// Stand-ins for fixtures (off-screen renders) and builds without adb: they do nothing and touch no hardware or process.
final class StubAdb: AdbControlling {
    let isAvailable: Bool
    init(available: Bool = true) { isAvailable = available }
    func ensureServer() async -> Bool { false }
    func mdnsServices() async -> [AdbMdnsService] { [] }
    func pair(endpoint: String, password: String) async -> AdbResult { AdbResult(status: 1, out: "", err: "") }
    func connect(endpoint: String) async -> AdbResult { AdbResult(status: 1, out: "", err: "") }
    func disconnect(endpoint: String?) async {}
    func shell(serial: String, _ command: String, timeout: TimeInterval) async -> AdbResult { AdbResult(status: 1, out: "", err: "") }
    func isOnline(serial: String) async -> Bool { false }
    func makeHelper(serial: String, package: CallAudioAndroidPackage) -> HelperProcess { NullHelper() }
    func killServer() {}
}

final class NullHelper: HelperProcess {
    var onLine: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    func start() -> Bool { false }
    func send(_ line: String) {}
    func stop() {}
}

@MainActor
final class NullAudioEngine: AudioEngineControlling {
    var muted = false
    var onConfigurationChange: (() -> Void)?
    func requestMicrophone() async -> Bool { false }
    func start(link: AudioLink, microphone: Bool, outputUID: String?, inputUID: String?) throws -> Bool { false }
    func stop() {}
}

// MARK: Remote, ring and walk-away stand-ins (fixtures and tests): nothing here posts an event, makes a sound or scans.

final class NullRingSound: RingSounding { func start() {}; func stop() {} }
final class NullVolume: VolumeControlling {
    func boost() -> VolumeSnapshot? { nil }
    func restore(_ snapshot: VolumeSnapshot) {}
}
@MainActor
final class NullRingPanel: RingPanelPresenting { func show(stop: @escaping () -> Void) {}; func hide() {} }
final class NullWaker: DisplayWaking { func wake() {} }
final class NullIdle: IdleTimeSource { func secondsSinceInput() -> TimeInterval? { nil } }
final class NullScanner: BleScanning {
    var onSample: ((Int) -> Void)?
    var onState: ((BluetoothStatus) -> Void)?
    func start(serviceUUID: String) {}
    func stop() {}
}
final class NullPoster: SyntheticEventPoster {
    func post(_ event: SyntheticEvent) {}
    func cursorLocation() -> CGPoint { .zero }
    func screenFrames() -> [CGRect] { [] }
}

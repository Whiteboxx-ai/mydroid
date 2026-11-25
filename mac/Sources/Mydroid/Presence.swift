import Foundation
import AppKit
import CoreBluetooth
import Intents
import Photos
import UniformTypeIdentifiers
import MydroidCore

/// BLE presence (PROTOCOL.md 7.1). Advertises only the pairing's service UUID, no characteristics, no data.
/// The phone watches for it to know the Mac is nearby and awake.
@MainActor
final class BlePresence: NSObject, CBPeripheralManagerDelegate {
    private(set) var status: BluetoothStatus = .unknown
    private(set) var advertising = false
    var onChange: () -> Void = {}

    private var manager: CBPeripheralManager?
    private var desired: CBUUID?

    /// Only bundles that declare the Bluetooth usage string can use CoreBluetooth without being killed.
    private static var available: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil
    }

    /// Call whenever the pairing changes. nil stops advertising.
    func sync(uuid: String?) {
        desired = uuid.flatMap { UUID(uuidString: $0) }.map { CBUUID(nsuuid: $0) }
        guard Self.available else { return }
        if desired != nil, manager == nil {
            manager = CBPeripheralManager(delegate: self, queue: .main)   // may show the Bluetooth permission prompt
        }
        refresh()
    }

    /// After wake from sleep, advertising may have silently stopped.
    func restart() {
        manager?.stopAdvertising()
        advertising = false
        // CoreBluetooth may still report the previous advertisement while the stop is queued.
        refresh(restarting: true)
    }

    private func refresh(restarting: Bool = false) {
        guard let m = manager else { setStatus(.unknown); return }
        switch m.state {
        case .poweredOn: setStatus(.on)
        case .poweredOff: setStatus(.off)
        case .unauthorized: setStatus(.unauthorized)
        case .unsupported: setStatus(.unsupported)
        default: setStatus(.unknown)
        }
        if m.state == .poweredOn, let uuid = desired {
            if restarting || !m.isAdvertising {
                m.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [uuid]])
            }
            advertising = true
        } else {
            if m.isAdvertising { m.stopAdvertising() }
            advertising = false
        }
        onChange()
    }

    private func setStatus(_ s: BluetoothStatus) { status = s }

    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated { self.refresh() }
    }

    nonisolated func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        MainActor.assumeIsolated {
            if error != nil { self.advertising = false; self.onChange() }
        }
    }
}

/// Follow macOS Focus, best effort. An ad-hoc signed app usually can't get Focus Status access;
/// then `available` is false and the option is hidden instead of shown broken.
@MainActor
final class FocusMonitor {
    private static var usable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.object(forInfoDictionaryKey: "NSFocusStatusUsageDescription") != nil
    }

    /// Whether to show the option: access can still be asked for, or was granted.
    var available: Bool {
        guard Self.usable else { return false }
        switch INFocusStatusCenter.default.authorizationStatus {
        case .notDetermined, .authorized: return true
        default: return false
        }
    }

    var isFocused: Bool {
        guard Self.usable, INFocusStatusCenter.default.authorizationStatus == .authorized else { return false }
        return INFocusStatusCenter.default.focusStatus.isFocused ?? false
    }

    /// Asks for access. Returns whether it was granted.
    func request() async -> Bool {
        guard Self.usable else { return false }
        return await withCheckedContinuation { cont in
            INFocusStatusCenter.default.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }
}

/// Adds received photos to Apple Photos (add-only access).
enum PhotosImporter {
    static var available: Bool { Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") != nil }

    static func requestAccess() async -> Bool {
        guard available else { return false }
        let s = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if s == .authorized || s == .limited { return true }
        if s != .notDetermined { return false }
        let r = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return r == .authorized || r == .limited
    }

    static func add(_ url: URL) async {
        guard available else { return }
        let s = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard s == .authorized || s == .limited else { return }
        let isVideo = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .movie) ?? false
        try? await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            let opts = PHAssetResourceCreationOptions()
            opts.shouldMoveFile = false
            req.addResource(with: isVideo ? .video : .photo, fileURL: url, options: opts)
        }
    }
}

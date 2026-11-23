import AppKit
@preconcurrency import AVFoundation
import Vision
import CoreImage
import MydroidCore

// PROTOCOL.md 14.4: import from Google Authenticator through this Mac's camera.
// Google Authenticator's export screen blocks screenshots, so the phone can't scan its own screen; the Mac's camera can.
// Nothing here writes to disk, logs, or keeps a frame: frames are read by Vision and dropped, the URIs live in `ImportTracker`
// only until the batch is whole, and they are gone from the Mac as soon as they have been sent.

// MARK: Detector

/// Reads QR codes with Vision. Stateless.
enum QRDetector {
    /// The text of every QR code in a camera frame.
    static func payloads(in buffer: CVPixelBuffer) -> [String] {
        run(VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]))
    }

    /// The text of every QR code in an image (tests).
    static func payloads(in image: CGImage) -> [String] {
        run(VNImageRequestHandler(cgImage: image, options: [:]))
    }

    private static func run(_ handler: VNImageRequestHandler) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        do { try handler.perform([request]) } catch { return [] }
        return (request.results ?? []).compactMap { $0.payloadStringValue }
    }
}

// MARK: Camera

enum CameraAccess: Equatable { case notDetermined, authorized, denied }

/// The camera, behind a protocol so tests and renders never turn one on.
@MainActor
protocol CameraSource: AnyObject {
    func access() -> CameraAccess
    func requestAccess() async -> Bool
    /// Starts the camera. `onPayloads` gets the QR texts found in a frame, on the main actor. Returns false when there is no camera.
    func start(onPayloads: @escaping @MainActor ([String]) -> Void) -> Bool
    func stop()
    /// For the live preview. nil when there is none (tests).
    var session: AVCaptureSession? { get }
    /// A still to draw instead of a live preview (renders).
    var stillPreview: NSImage? { get }
}

extension CameraSource {
    var session: AVCaptureSession? { nil }
    var stillPreview: NSImage? { nil }
}

/// The real camera: an `AVCaptureSession` with a video output read by Vision about five times a second.
@MainActor
final class SystemCamera: NSObject, CameraSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let capture = AVCaptureSession()
    private let queue = DispatchQueue(label: "mydroid.camera.import", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private let gate = FrameGate()
    private var configured = false
    private var onPayloads: (@MainActor ([String]) -> Void)?

    var session: AVCaptureSession? { capture }

    func access() -> CameraAccess {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func requestAccess() async -> Bool { await AVCaptureDevice.requestAccess(for: .video) }

    func start(onPayloads: @escaping @MainActor ([String]) -> Void) -> Bool {
        self.onPayloads = onPayloads
        if !configured {
            guard let device = Self.pickCamera(), let input = try? AVCaptureDeviceInput(device: device) else { return false }
            capture.beginConfiguration()
            if capture.canSetSessionPreset(.hd1280x720) { capture.sessionPreset = .hd1280x720 }
            guard capture.canAddInput(input) else { capture.commitConfiguration(); return false }
            capture.addInput(input)
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard capture.canAddOutput(output) else { capture.commitConfiguration(); return false }
            capture.addOutput(output)
            // Vision reads the raw frame, never the mirrored one the preview shows.
            if let c = output.connection(with: .video) {
                c.automaticallyAdjustsVideoMirroring = false
                if c.isVideoMirroringSupported { c.isVideoMirrored = false }
            }
            capture.commitConfiguration()
            configured = true
        }
        gate.reset()
        let s = capture
        queue.async { if !s.isRunning { s.startRunning() } }
        return true
    }

    func stop() {
        onPayloads = nil
        let s = capture
        queue.async { if s.isRunning { s.stopRunning() } }
    }

    /// The Mac's own camera first; a phone offered as a Continuity Camera is only a fallback.
    private static func pickCamera() -> AVCaptureDevice? {
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices
        return found.first { $0.deviceType == .builtInWideAngleCamera } ?? found.first ?? AVCaptureDevice.default(for: .video)
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard gate.shouldProcess(), let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let found = autoreleasepool { QRDetector.payloads(in: buffer) }
        guard !found.isEmpty else { return }
        Task { @MainActor [weak self] in self?.onPayloads?(found) }
    }
}

/// Lets about five frames a second through.
final class FrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private let interval: TimeInterval
    init(interval: TimeInterval = 0.2) { self.interval = interval }
    func reset() { lock.lock(); last = .distantPast; lock.unlock() }
    func shouldProcess(now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard now.timeIntervalSince(last) >= interval else { return false }
        last = now
        return true
    }
}

// MARK: Controller

/// What the import window shows.
enum ImportPhase: Equatable {
    case offline
    case askingForCamera
    case cameraDenied
    case noCamera
    case scanning
    /// Sent; the phone is asking to add them.
    case approving
    case done(added: Int, skipped: Int)
    case failed(ImportFailure)
}

enum ImportFailure: Equatable {
    case cancelled, locked, invalid, offline, timeout, other

    var title: String {
        switch self {
        case .cancelled: return "You cancelled it on your phone"
        case .locked: return "Your phone is locked"
        case .invalid: return "Those codes couldn\u{2019}t be read"
        case .offline: return "Your phone disconnected"
        case .timeout: return "Your phone didn\u{2019}t answer"
        case .other: return "Something went wrong"
        }
    }

    var detail: String {
        switch self {
        case .cancelled: return "Nothing was added."
        case .locked: return "Unlock your phone, then scan again."
        case .invalid: return "Export again and scan the new codes."
        case .offline: return "Reconnect, then scan again."
        case .timeout: return "Nothing was added. Scan again."
        case .other: return "Nothing was added. Try again."
        }
    }

    init(_ o: AuthImportOutcome) {
        switch o {
        case .cancelled: self = .cancelled
        case .locked: self = .locked
        case .invalid: self = .invalid
        case .offline: self = .offline
        case .timeout: self = .timeout
        case .added, .failed: self = .other
        }
    }
}

/// Drives the camera window: permission, scanning, batch progress, sending, the phone's answer. All state is in memory.
@MainActor @Observable
final class CameraImportController {
    private(set) var phase: ImportPhase = .scanning
    /// Parts read so far and how many there are, once a multi-part export has been seen.
    private(set) var progress: (scanned: Int, total: Int)?
    /// A gentle line under the preview ("That's not a transfer code").
    private(set) var hint: String?

    @ObservationIgnored let camera: CameraSource
    @ObservationIgnored private let importer: AuthImporting
    @ObservationIgnored private var tracker = ImportTracker()
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private var hintTask: Task<Void, Never>?
    @ObservationIgnored private var connected: Bool
    @ObservationIgnored private var generation = 0

    init(camera: CameraSource, importer: AuthImporting, phoneConnected: Bool) {
        self.camera = camera; self.importer = importer; self.connected = phoneConnected
        if !phoneConnected { phase = .offline }
    }

    /// Window appeared (or "Scan again"): ask for the camera if needed and start.
    func begin() {
        generation += 1
        tracker.reset(); progress = nil; hint = nil
        sendTask?.cancel(); sendTask = nil
        guard connected else { camera.stop(); phase = .offline; return }
        switch camera.access() {
        case .authorized: startCamera()
        case .denied: phase = .cameraDenied
        case .notDetermined:
            phase = .askingForCamera
            let g = generation
            Task { [weak self] in
                guard let self else { return }
                let ok = await camera.requestAccess()
                guard g == generation else { return }
                if ok { startCamera() } else { phase = .cameraDenied }
            }
        }
    }

    private func startCamera() {
        let ok = camera.start { [weak self] found in self?.ingest(found) }
        phase = ok ? .scanning : .noCamera
    }

    /// The phone connected or went away while the window is open.
    func phoneConnection(_ up: Bool) {
        guard up != connected else { return }
        connected = up
        if up {
            if phase == .offline { begin() }
        } else {
            switch phase {
            case .scanning, .askingForCamera, .cameraDenied, .noCamera:
                camera.stop(); tracker.reset(); progress = nil; phase = .offline
            default: break      // an answer from the phone is still on its way, or the result is on screen
            }
        }
    }

    /// Camera off, everything forgotten. Called when the window closes.
    func stop() {
        generation += 1
        camera.stop()
        tracker.reset()
        sendTask?.cancel(); sendTask = nil
        hintTask?.cancel()
        progress = nil; hint = nil
    }

    /// QR texts from one frame. Repeats of the same code change nothing.
    func ingest(_ payloads: [String]) {
        guard phase == .scanning else { return }
        for raw in payloads {
            switch tracker.ingest(raw) {
            case .duplicate: break
            case .notForUs: show("Not a Google Authenticator transfer code")
            case .unreadable: show("Hold steady")
            case .finishBatchFirst: show("Finish this export first")
            case .accepted(let n, let of): progress = (n, of); clearHint()
            case .restarted(let n, let of): progress = (n, of); show("Different export. Started over.")
            case .complete(let uris):
                send(uris)
                return
            }
        }
    }

    /// The batch is whole: camera off, tell the phone, forget the strings.
    private func send(_ uris: [String]) {
        camera.stop()
        clearHint()
        phase = .approving
        let importer = importer
        let g = generation
        // The array moves into the task; this object keeps nothing of it.
        sendTask = Task { [weak self] in
            var batch: [String]? = uris
            let outcome = await importer.importAccounts(uris: batch ?? [])
            batch = nil
            guard let self, g == self.generation else { return }
            self.finish(outcome)
        }
    }

    private func finish(_ outcome: AuthImportOutcome) {
        sendTask = nil
        if case .added(let a, let s) = outcome { phase = .done(added: a, skipped: s) } else { phase = .failed(ImportFailure(outcome)) }
    }

    private func show(_ text: String) {
        hint = text
        hintTask?.cancel()
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            if !Task.isCancelled { self?.hint = nil }
        }
    }

    private func clearHint() { hintTask?.cancel(); hint = nil }

    // MARK: Fixtures (renders)

    #if DEBUG
    func fixture(phase: ImportPhase, progress: (Int, Int)? = nil, hint: String? = nil) {
        self.phase = phase; self.progress = progress.map { (scanned: $0.0, total: $0.1) }; self.hint = hint
    }
    #endif
}

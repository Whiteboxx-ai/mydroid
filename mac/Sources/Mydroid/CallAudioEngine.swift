import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import os
import MydroidCore

// Plays the phone's call audio on the Mac and (when allowed) sends the Mac's microphone back.
// Audio lives only in the buffers that are in flight; nothing is recorded, written or logged.

// MARK: Devices

struct AudioDevice: Identifiable, Hashable {
    var uid: String
    var name: String
    var id: String { uid }
}

enum AudioDevices {
    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr, let s = cf?.takeRetainedValue() else { return nil }
        return s as String
    }

    private static func hasStreams(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func all() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func list(scope: AudioObjectPropertyScope) -> [AudioDevice] {
        all().compactMap { id in
            guard hasStreams(id, scope: scope), let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            // Voice processing makes private aggregate devices of its own; they aren't choices.
            if name.hasPrefix("VPAUAggregate") || name.hasPrefix("CADefaultDeviceAggregate") { return nil }
            return AudioDevice(uid: uid, name: name)
        }
    }

    static func outputs() -> [AudioDevice] { list(scope: kAudioObjectPropertyScopeOutput) }
    static func inputs() -> [AudioDevice] { list(scope: kAudioObjectPropertyScopeInput) }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        all().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }
}

// MARK: The audio path (runs on audio threads)

/// Everything the render and capture callbacks touch. The downlink side is used only by the render thread and the uplink side only
/// by the capture thread; the mute flag is the one shared value.
final class AudioPath: @unchecked Sendable {
    private let link: AudioLink
    private let mutedFlag = OSAllocatedUnfairLock(initialState: false)

    private var fifo = FloatFIFO(capacity: 16_384)
    private let down: StreamResampler

    private var up: StreamResampler?
    private var upRate: Double = 0
    private var pending: [Float] = []

    init(link: AudioLink, outputRate: Double) {
        self.link = link
        down = StreamResampler(inRate: Double(CallAudioFormat.sampleRate), outRate: outputRate)
    }

    var muted: Bool {
        get { mutedFlag.withLock { $0 } }
        set { mutedFlag.withLock { $0 = newValue } }
    }

    /// Fills `n` mono samples at the hardware rate from the jitter buffer.
    func render(_ n: Int, into out: UnsafeMutablePointer<Float>) {
        var guardrail = 0
        while fifo.count < n, guardrail < 8 {
            fifo.append(down.process(PCM.floats(from: link.pullFrame().samples)))
            guardrail += 1
        }
        fifo.read(n, into: out)
    }

    /// Takes microphone samples at the hardware rate and sends whole 20 ms frames to the phone.
    func capture(_ samples: UnsafePointer<Float>, count: Int, rate: Double) {
        if up == nil || upRate != rate {
            up = StreamResampler(inRate: rate, outRate: Double(CallAudioFormat.sampleRate))
            upRate = rate
            pending.removeAll(keepingCapacity: true)
        }
        pending.append(contentsOf: up!.process(Array(UnsafeBufferPointer(start: samples, count: count))))
        while pending.count >= CallAudioFormat.frameSamples {
            let frame = PCM.int16(from: pending[0..<CallAudioFormat.frameSamples])
            pending.removeFirst(CallAudioFormat.frameSamples)
            if !muted { link.send(frame: frame) }
        }
    }
}

// MARK: Engine

enum CallAudioEngineError: Error, LocalizedError {
    case noOutput
    var errorDescription: String? { "There's no audio output on this Mac." }
}

@MainActor
final class CallAudioEngine: AudioEngineControlling {
    var muted = false { didSet { path?.muted = muted } }
    var onConfigurationChange: (() -> Void)?

    private var engine: AVAudioEngine?
    private var path: AudioPath?
    private var usesMic = false
    private var observer: NSObjectProtocol?
    private var startedAt = Date.distantPast

    func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    @discardableResult
    func start(link: AudioLink, microphone wantsMic: Bool, outputUID: String?, inputUID: String?) throws -> Bool {
        stop()
        let engine = AVAudioEngine()
        var microphone = wantsMic
        if microphone {
            // Echo cancellation: the Mac's speakers must not be heard by its own microphone. If this Mac can't do it (no
            // microphone, or voice processing refuses), listen only rather than fail the call.
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
                engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
                Self.select(inputUID, on: engine.inputNode)
                if engine.inputNode.inputFormat(forBus: 0).channelCount == 0 { microphone = false }
            } catch {
                microphone = false
            }
        }
        usesMic = microphone
        Self.select(outputUID, on: engine.outputNode)

        var rate = engine.outputNode.inputFormat(forBus: 0).sampleRate
        if rate <= 0 { rate = 48_000 }
        let path = AudioPath(link: link, outputRate: rate)
        path.muted = muted
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else { throw CallAudioEngineError.noOutput }
        let source = AVAudioSourceNode(format: format) { _, _, frames, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard let p = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            path.render(Int(frames), into: p)
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        if microphone {
            engine.inputNode.installTap(onBus: 0, bufferSize: 960, format: nil) { buffer, _ in
                guard let ch = buffer.floatChannelData else { return }
                path.capture(ch[0], count: Int(buffer.frameLength), rate: buffer.format.sampleRate)
            }
        }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Date().timeIntervalSince(self.startedAt) > 1.5 else { return }   // starting makes one of these itself
                self.onConfigurationChange?()
            }
        }
        engine.prepare()
        do { try engine.start() } catch {
            if microphone { engine.inputNode.removeTap(onBus: 0) }
            if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
            throw error
        }
        startedAt = Date()
        self.engine = engine
        self.path = path
        return microphone
    }

    func stop() {
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        guard let engine else { return }
        if usesMic { engine.inputNode.removeTap(onBus: 0) }
        engine.stop()
        self.engine = nil
        path = nil
        usesMic = false
    }

    /// Points a node at a chosen device. No choice (or a device that has gone) leaves the system default.
    private static func select(_ uid: String?, on node: AVAudioIONode) {
        guard let uid, var id = AudioDevices.deviceID(forUID: uid), let unit = node.audioUnit else { return }
        _ = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
    }
}

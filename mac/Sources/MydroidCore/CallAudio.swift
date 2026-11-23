import Foundation
import CryptoKit
import Darwin
import os

// Mac call audio (PROTOCOL.md section 8). The pieces that need no AppKit or AVFoundation live here so they can be tested:
// the packet cipher, the jitter buffer, the resampler, PCM helpers and the UDP link.
// Call audio is never recorded or stored. Only levels and counts leave these types.

public enum CallAudioFormat {
    public static let sampleRate = 16_000
    public static let frameMillis = 20
    public static let frameSamples = 320            // 20 ms of PCM16 mono at 16 kHz
    public static let frameBytes = 640
    public static let tagBytes = 16
    public static let packetBytes = 4 + frameBytes + tagBytes
}

// MARK: Packet crypto

public enum AudioCrypto {
    /// Each direction has its own key: `HKDF(key, info = "mydroid audio down" | "mydroid audio up")`.
    public static func downKey(_ key: Data) -> Data { MydroidCrypto.hkdf(ikm: key, salt: Data(), info: "mydroid audio down", length: 32) }
    public static func upKey(_ key: Data) -> Data { MydroidCrypto.hkdf(ikm: key, salt: Data(), info: "mydroid audio up", length: 32) }
}

public enum AudioPacketError: Error, Equatable { case badLength, authenticationFailed }

/// `u32 seq (big endian) || AES-256-GCM(key, nonce = 4 zero bytes || u64 seq, frame)` where the GCM output is ciphertext then the 16-byte tag.
public struct AudioPacketCipher: Sendable {
    private let key: SymmetricKey
    public init(key: Data) { self.key = SymmetricKey(data: key) }

    static func nonce(_ seq: UInt32) -> Data { FrameCipher.nonceBytes(UInt64(seq)) }

    public func seal(seq: UInt32, frame: Data) throws -> Data {
        let box = try AES.GCM.seal(frame, using: key, nonce: AES.GCM.Nonce(data: Self.nonce(seq)))
        var out = Data(capacity: 4 + frame.count + CallAudioFormat.tagBytes)
        var be = seq.bigEndian
        withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        out.append(box.ciphertext)
        out.append(box.tag)
        return out
    }

    public func open(_ packet: Data) throws -> (seq: UInt32, frame: Data) {
        let packet = Data(packet)
        guard packet.count >= 4 + CallAudioFormat.tagBytes else { throw AudioPacketError.badLength }
        let seq = packet.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let ct = packet.dropFirst(4).dropLast(CallAudioFormat.tagBytes)
        let tag = packet.suffix(CallAudioFormat.tagBytes)
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: Self.nonce(seq)), ciphertext: ct, tag: tag)
            return (seq, try AES.GCM.open(box, using: key))
        } catch {
            throw AudioPacketError.authenticationFailed
        }
    }
}

// MARK: PCM helpers

public enum PCM {
    /// Little-endian PCM16 bytes to samples.
    public static func samples(from data: Data) -> [Int16] {
        let d = Data(data)
        let n = d.count / 2
        var out = [Int16](repeating: 0, count: n)
        for i in 0..<n { out[i] = Int16(bitPattern: UInt16(d[d.startIndex + 2 * i]) | UInt16(d[d.startIndex + 2 * i + 1]) << 8) }
        return out
    }

    public static func data(from samples: [Int16]) -> Data {
        var d = Data(capacity: samples.count * 2)
        for s in samples { let u = UInt16(bitPattern: s); d.append(UInt8(u & 0xff)); d.append(UInt8(u >> 8)) }
        return d
    }

    public static func floats(from samples: [Int16]) -> [Float] { samples.map { Float($0) / 32768 } }

    public static func int16(from floats: ArraySlice<Float>) -> [Int16] {
        floats.map { Int16(max(-32768, min(32767, ($0 * 32768).rounded()))) }
    }

    /// Root mean square of PCM16, 0 to 1.
    public static func rms(_ samples: [Int16]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Double = 0
        for s in samples { let f = Double(s) / 32768; sum += f * f }
        return Float((sum / Double(samples.count)).squareRoot())
    }

    /// A 0 to 1 meter position for an RMS value: -50 dBFS is empty, 0 dBFS is full.
    public static func meter(rms: Float) -> Float {
        guard rms > 0.000_01 else { return 0 }
        let db = 20 * log10(Double(rms))
        return Float(max(0, min(1, (db + 50) / 50)))
    }
}

// MARK: Jitter buffer

/// Reorders and paces downlink frames. About 60 ms deep (three 20 ms frames): it waits for that much before it starts playing,
/// drops frames that arrive after their turn, and conceals a missing frame by repeating the last one, fading to silence.
/// Not thread safe by itself; `AudioLink` wraps it in a lock.
public struct JitterBuffer {
    public struct Stats: Equatable, Sendable {
        public var received = 0
        public var played = 0
        public var lost = 0          // frames concealed because a later one had already arrived
        public var late = 0          // arrived after their turn, dropped
        public var duplicate = 0
        public var overflow = 0      // dropped from the front because the buffer ran too deep
        public var underruns = 0     // nothing at all to play, buffering again
        public var resyncs = 0
    }

    public enum Kind: Equatable, Sendable { case normal, concealed, buffering }

    public let targetFrames: Int
    public let maxFrames: Int
    public let frameSamples: Int
    public private(set) var stats = Stats()

    private var frames: [UInt32: [Int16]] = [:]
    private var nextSeq: UInt32 = 0
    private var started = false
    private var seen = false
    private var last: [Int16]
    private var concealRun = 0
    private static let resyncDistance = 100        // two seconds of frames either way

    public init(targetFrames: Int = 3, maxFrames: Int = 8, frameSamples: Int = CallAudioFormat.frameSamples) {
        self.targetFrames = max(1, targetFrames)
        self.maxFrames = max(self.targetFrames + 1, maxFrames)
        self.frameSamples = frameSamples
        last = [Int16](repeating: 0, count: frameSamples)
    }

    public var depth: Int { frames.count }

    private static func diff(_ a: UInt32, _ b: UInt32) -> Int { Int(Int32(bitPattern: a &- b)) }

    public mutating func push(seq: UInt32, frame: [Int16]) {
        stats.received += 1
        guard frame.count == frameSamples else { return }
        if !seen {
            seen = true
            nextSeq = seq
        } else if abs(Self.diff(seq, nextSeq)) > Self.resyncDistance {
            // The sender restarted or we were away for a long time.
            frames.removeAll(keepingCapacity: true)
            started = false
            nextSeq = seq
            concealRun = 0
            stats.resyncs += 1
        }
        if Self.diff(seq, nextSeq) < 0 {
            // Before playing starts a slightly earlier frame can still slot in; afterwards it is late.
            if !started && frames[seq] == nil && Self.diff(nextSeq, seq) <= targetFrames {
                nextSeq = seq
            } else {
                stats.late += 1
                return
            }
        }
        if frames[seq] != nil { stats.duplicate += 1; return }
        frames[seq] = frame
        while frames.count > maxFrames, let oldest = frames.keys.min(by: { Self.diff($0, $1) < 0 }) {
            frames.removeValue(forKey: oldest)
            stats.overflow += 1
            if Self.diff(oldest, nextSeq) >= 0 { nextSeq = oldest &+ 1 }
        }
        if !started && frames.count >= targetFrames {
            started = true
            if let first = frames.keys.min(by: { Self.diff($0, $1) < 0 }) { nextSeq = first }
        }
    }

    /// The next 20 ms to play. Call once per frame period.
    public mutating func pop() -> (samples: [Int16], kind: Kind) {
        guard started else { return ([Int16](repeating: 0, count: frameSamples), .buffering) }
        if let f = frames.removeValue(forKey: nextSeq) {
            nextSeq &+= 1
            last = f
            concealRun = 0
            stats.played += 1
            return (f, .normal)
        }
        if let ahead = frames.keys.min(by: { Self.diff($0, $1) < 0 }), Self.diff(ahead, nextSeq) > 0 {
            // A later frame is here and this one isn't: it is lost (or too late to matter).
            nextSeq &+= 1
            stats.lost += 1
            return (concealment(), .concealed)
        }
        // Nothing buffered at all. Play out the tail of the last frame, then wait until the buffer refills.
        stats.underruns += 1
        started = false
        return (concealment(), .concealed)
    }

    private mutating func concealment() -> [Int16] {
        defer { concealRun += 1 }
        guard concealRun < 3 else { return [Int16](repeating: 0, count: frameSamples) }
        let gain = Float(pow(0.6, Double(concealRun + 1)))
        return last.map { Int16(Float($0) * gain) }
    }

    public mutating func reset() {
        frames.removeAll()
        started = false
        seen = false
        concealRun = 0
        last = [Int16](repeating: 0, count: frameSamples)
    }
}

// MARK: Resampler

/// Streaming windowed-sinc resampler for mono Float32. 16 kHz to or from a hardware rate.
/// Feed it any chunk size; it keeps what it needs between calls. The kernel is tabulated per fractional position
/// (1024 phases, each normalised to unit gain) so the audio thread does multiply-adds only.
public final class StreamResampler {
    public let inRate: Double
    public let outRate: Double
    private let step: Double
    private let reach: Int                  // taps on each side of the centre
    private static let phases = 1024
    private let table: [Float]              // phases x (2 * reach), taps for n = base - reach + 1 ... base + reach
    private var buf: [Float]
    private var t: Double                   // next output position, in input samples relative to buf[0]

    public init(inRate: Double, outRate: Double, zeroCrossings: Int = 8) {
        self.inRate = inRate
        self.outRate = outRate
        let cutoff = min(1, outRate / inRate)
        let halfWidth = Double(zeroCrossings) / cutoff
        step = inRate / outRate
        reach = Int(halfWidth.rounded(.up))
        let taps = 2 * reach
        var tab = [Float](repeating: 0, count: Self.phases * taps)
        for p in 0..<Self.phases {
            let frac = Double(p) / Double(Self.phases)
            var sum = 0.0
            var row = [Double](repeating: 0, count: taps)
            for k in 0..<taps {
                let x = Double(k - reach + 1) - frac
                guard abs(x) < halfWidth else { continue }
                let arg = Double.pi * cutoff * x
                let sinc = abs(arg) < 1e-9 ? 1.0 : sin(arg) / arg
                row[k] = sinc * (0.5 + 0.5 * cos(Double.pi * x / halfWidth))
                sum += row[k]
            }
            for k in 0..<taps { tab[p * taps + k] = Float(sum != 0 ? row[k] / sum : 0) }
        }
        table = tab
        buf = [Float](repeating: 0, count: reach)
        t = Double(reach)
    }

    public var isPassthrough: Bool { inRate == outRate }

    public func process(_ input: [Float]) -> [Float] {
        if isPassthrough { return input }
        buf.append(contentsOf: input)
        var out: [Float] = []
        out.reserveCapacity(Int(Double(input.count) / step) + 2)
        let taps = 2 * reach
        buf.withUnsafeBufferPointer { b in
            table.withUnsafeBufferPointer { tab in
                while true {
                    var base = Int(t.rounded(.down))
                    var phase = Int(((t - Double(base)) * Double(Self.phases)).rounded())
                    if phase == Self.phases { phase = 0; base += 1 }
                    guard base + reach < b.count else { break }
                    let first = base - reach + 1
                    var acc: Float = 0
                    let row = phase * taps
                    for k in 0..<taps { acc += b[first + k] * tab[row + k] }
                    out.append(acc)
                    t += step
                }
            }
        }
        let drop = max(0, Int(t.rounded(.down)) - reach)
        if drop > 0 { buf.removeFirst(drop); t -= Double(drop) }
        return out
    }

    public func reset() {
        buf = [Float](repeating: 0, count: reach)
        t = Double(reach)
    }
}

/// A fixed-capacity circular queue of Float samples, for handing resampled audio to a render callback.
public struct FloatFIFO {
    private var storage: [Float]
    private var head = 0
    public private(set) var count = 0
    public init(capacity: Int) { storage = [Float](repeating: 0, count: capacity) }
    public var capacity: Int { storage.count }

    /// Drops the oldest samples if it would overflow.
    public mutating func append(_ xs: [Float]) {
        for x in xs {
            if count == storage.count { head = (head + 1) % storage.count; count -= 1 }
            storage[(head + count) % storage.count] = x
            count += 1
        }
    }

    /// Fills `into` (`n` samples) and returns how many real samples it held; the rest is zero.
    @discardableResult
    public mutating func read(_ n: Int, into out: UnsafeMutablePointer<Float>) -> Int {
        let m = min(n, count)
        for i in 0..<m { out[i] = storage[(head + i) % storage.count] }
        if m < n { for i in m..<n { out[i] = 0 } }
        head = (head + m) % storage.count
        count -= m
        return m
    }

    public mutating func removeAll() { head = 0; count = 0 }
}

// MARK: UDP link

public struct AudioLinkStats: Equatable, Sendable {
    public var jitter = JitterBuffer.Stats()
    public var rejected = 0          // bad length or failed authentication
    public var sent = 0
    public var rxLevel: Float = 0    // RMS of the last played frame, 0 to 1
    public var txLevel: Float = 0
}

public enum AudioLinkError: Error, Equatable { case socket(String) }

/// The Mac end of the audio path: a UDP socket that receives encrypted downlink frames into a jitter buffer and sends
/// encrypted uplink frames back to the address the downlink came from. Only authenticated packets count.
public final class AudioLink {
    public let port: UInt16
    private let fd: Int32
    private let down: AudioPacketCipher
    private let up: AudioPacketCipher
    private let queue = DispatchQueue(label: "com.mydroid.audio.rx", qos: .userInteractive)
    private var source: DispatchSourceRead?
    private struct State {
        var jitter: JitterBuffer
        var stats = AudioLinkStats()
        var peer: [UInt8]? = nil        // raw sockaddr_in of the last authenticated downlink source
        var upSeq: UInt32 = 0
        var closed = false
    }
    private let state: OSAllocatedUnfairLock<State>

    /// - Parameters:
    ///   - key: the session key (32 bytes) that was sent to the helper in `hello`.
    ///   - port: 0 picks a free one.
    public init(key: Data, port: UInt16 = 0, jitter: JitterBuffer = JitterBuffer()) throws {
        down = AudioPacketCipher(key: AudioCrypto.downKey(key))
        up = AudioPacketCipher(key: AudioCrypto.upKey(key))
        state = OSAllocatedUnfairLock(initialState: State(jitter: jitter))
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { throw AudioLinkError.socket("socket: \(String(cString: strerror(errno)))") }
        var size: Int32 = 1 << 18
        setsockopt(s, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { let e = String(cString: strerror(errno)); close(s); throw AudioLinkError.socket("bind: \(e)") }
        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        self.port = UInt16(bigEndian: actual.sin_port)
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        fd = s
    }

    deinit { stop() }

    public func start() {
        guard source == nil else { return }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.drain() }
        source = src
        src.resume()
    }

    /// Stops receiving and closes the socket. The link can't be restarted.
    public func stop() {
        if let src = source {
            source = nil
            // The descriptor closes once the source is gone, never from under a read.
            src.setCancelHandler { [weak self] in self?.closeSocket() }
            src.cancel()
        } else {
            closeSocket()
        }
    }

    private func closeSocket() {
        state.withLock {
            guard !$0.closed else { return }
            $0.closed = true
            close(fd)
        }
    }

    private func drain() {
        var buf = [UInt8](repeating: 0, count: 2048)
        while true {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &fromLen) }
            }
            if n < 0 { return }                    // EAGAIN: drained
            ingest(Data(buf[0..<n]), from: from)
        }
    }

    /// Public so tests can feed packets without a socket.
    public func ingest(_ packet: Data, from: sockaddr_in) {
        guard packet.count == CallAudioFormat.packetBytes, let (seq, frame) = try? down.open(packet),
              frame.count == CallAudioFormat.frameBytes else {
            state.withLock { $0.stats.rejected += 1 }
            return
        }
        let samples = PCM.samples(from: frame)
        var f = from
        let raw = withUnsafeBytes(of: &f) { Array($0) }
        state.withLock {
            $0.peer = raw
            $0.jitter.push(seq: seq, frame: samples)
        }
    }

    public var hasPeer: Bool { state.withLock { $0.peer != nil } }

    /// The next 20 ms to play (silence while buffering). Call once per frame period from the playback side.
    public func pullFrame() -> (samples: [Int16], kind: JitterBuffer.Kind) {
        state.withLock {
            let r = $0.jitter.pop()
            $0.stats.rxLevel = PCM.rms(r.samples)
            return r
        }
    }

    /// Encrypts and sends one 20 ms uplink frame to the phone. Does nothing until a downlink packet has told us where it is.
    @discardableResult
    public func send(frame: [Int16]) -> Bool {
        guard frame.count == CallAudioFormat.frameSamples else { return false }
        let (peer, seq): ([UInt8]?, UInt32) = state.withLock {
            let s = $0.upSeq
            $0.upSeq &+= 1
            $0.stats.txLevel = PCM.rms(frame)
            return ($0.peer, s)
        }
        guard let peer, let packet = try? up.seal(seq: seq, frame: PCM.data(from: frame)) else { return false }
        // Sending under the lock keeps the descriptor from closing (and being reused) underneath us. UDP sends don't block.
        return state.withLock { st in
            guard !st.closed else { return false }
            let sent: Int = packet.withUnsafeBytes { p in
                peer.withUnsafeBytes { a in
                    sendto(fd, p.baseAddress, p.count, 0, a.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(peer.count))
                }
            }
            if sent == packet.count { st.stats.sent += 1; return true }
            return false
        }
    }

    public var stats: AudioLinkStats {
        state.withLock { var s = $0.stats; s.jitter = $0.jitter.stats; return s }
    }
}

// MARK: Local address

public enum LocalAddress {
    /// The IPv4 address of the interface the Mac would use to reach `host` (no packet is sent).
    public static func reaching(host: String) -> String? {
        var hints = addrinfo(); hints.ai_family = AF_INET; hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "9", &hints, &res) == 0, let info = res else { return nil }
        defer { freeaddrinfo(res) }
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { return nil }
        defer { close(s) }
        guard connect(s, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else { return nil }
        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        guard ok == 0 else { return nil }
        var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var a = local.sin_addr
        guard inet_ntop(AF_INET, &a, &ip, socklen_t(ip.count)) != nil else { return nil }
        let text = String(cString: ip)
        return text == "0.0.0.0" ? nil : text
    }
}

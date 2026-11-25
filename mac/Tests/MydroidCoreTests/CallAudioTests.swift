import XCTest
import CryptoKit
import Darwin
@testable import MydroidCore

final class CallAudioPacketTests: XCTestCase {
    private let key = Data((0..<32).map { UInt8($0) })

    private func frame(_ v: Int16) -> [Int16] { [Int16](repeating: v, count: CallAudioFormat.frameSamples) }

    func testKeysAreSeparatedPerDirection() {
        XCTAssertEqual(AudioCrypto.downKey(key).count, 32)
        XCTAssertNotEqual(AudioCrypto.downKey(key), AudioCrypto.upKey(key))
        XCTAssertNotEqual(AudioCrypto.downKey(key), key)
        XCTAssertEqual(AudioCrypto.downKey(key), MydroidCrypto.hkdf(ikm: key, salt: Data(), info: "mydroid audio down", length: 32))
    }

    func testPacketLayoutMatchesSpec() throws {
        let c = AudioPacketCipher(key: AudioCrypto.downKey(key))
        let pcm = PCM.data(from: frame(1234))
        let p = try c.seal(seq: 5, frame: pcm)
        XCTAssertEqual(p.count, 660)                                   // 4 + 640 + 16
        XCTAssertEqual(Array(p.prefix(4)), [0, 0, 0, 5])                // u32 seq, big endian
        // Independent decryption with nonce = 4 zero bytes || u64 seq.
        let nonce = try AES.GCM.Nonce(data: Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5]))
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: p.dropFirst(4).dropLast(16), tag: p.suffix(16))
        XCTAssertEqual(try AES.GCM.open(box, using: SymmetricKey(data: AudioCrypto.downKey(key))), pcm)
        let opened = try c.open(p)
        XCTAssertEqual(opened.seq, 5)
        XCTAssertEqual(opened.frame, pcm)
    }

    func testTamperedOrWrongKeyIsRejected() throws {
        let c = AudioPacketCipher(key: AudioCrypto.downKey(key))
        var p = try c.seal(seq: 9, frame: PCM.data(from: frame(7)))
        XCTAssertThrowsError(try AudioPacketCipher(key: AudioCrypto.upKey(key)).open(p)) { XCTAssertEqual($0 as? AudioPacketError, .authenticationFailed) }
        p[10] ^= 0x01
        XCTAssertThrowsError(try c.open(p)) { XCTAssertEqual($0 as? AudioPacketError, .authenticationFailed) }
        // A changed seq changes the nonce, so it fails too.
        var q = try c.seal(seq: 9, frame: PCM.data(from: frame(7)))
        q[3] = 10
        XCTAssertThrowsError(try c.open(q))
        XCTAssertThrowsError(try c.open(Data(count: 10))) { XCTAssertEqual($0 as? AudioPacketError, .badLength) }
    }

    func testPCMRoundTripAndLevels() {
        let s: [Int16] = [0, 1, -1, 32767, -32768, 12345]
        XCTAssertEqual(PCM.samples(from: PCM.data(from: s)), s)
        XCTAssertEqual(PCM.data(from: [0x0102]), Data([0x02, 0x01]))     // little endian
        XCTAssertEqual(PCM.rms([0, 0, 0]), 0)
        XCTAssertEqual(PCM.rms([Int16](repeating: 16384, count: 10)), 0.5, accuracy: 1e-4)
        XCTAssertEqual(PCM.meter(rms: 0), 0)
        XCTAssertEqual(PCM.meter(rms: 1), 1)
        XCTAssertGreaterThan(PCM.meter(rms: 0.1), PCM.meter(rms: 0.01))
    }
}

final class JitterBufferTests: XCTestCase {
    private func f(_ v: Int16) -> [Int16] { [Int16](repeating: v, count: CallAudioFormat.frameSamples) }

    /// Frame content identifies its sequence number: seq + 1000.
    private func push(_ j: inout JitterBuffer, _ seqs: [UInt32]) { for s in seqs { j.push(seq: s, frame: f(Int16(s) + 1000)) } }

    func testWaitsForSixtyMillisecondsThenPlaysInOrder() {
        var j = JitterBuffer()
        push(&j, [0, 1])
        XCTAssertEqual(j.pop().kind, .buffering)                       // 40 ms is not enough yet
        push(&j, [2])
        for s in 0..<3 {
            let r = j.pop()
            XCTAssertEqual(r.kind, .normal)
            XCTAssertEqual(r.samples.first, Int16(s) + 1000)
        }
        XCTAssertEqual(j.stats.played, 3)
        XCTAssertEqual(j.stats.lost, 0)
    }

    func testReorderedPacketsPlayInOrderWithoutLoss() {
        var j = JitterBuffer()
        push(&j, [0, 2, 1, 4, 3, 5])
        var played: [Int16] = []
        for _ in 0..<6 { let r = j.pop(); XCTAssertEqual(r.kind, .normal); played.append(r.samples[0]) }
        XCTAssertEqual(played, [1000, 1001, 1002, 1003, 1004, 1005])
        XCTAssertEqual(j.stats.lost, 0)
        XCTAssertEqual(j.stats.late, 0)
    }

    func testLossIsConcealedAndDoesNotShiftLaterFrames() {
        var j = JitterBuffer()
        push(&j, [0, 1, 3, 4, 5])                                      // 2 never arrives
        var kinds: [JitterBuffer.Kind] = [], firsts: [Int16] = []
        for _ in 0..<5 { let r = j.pop(); kinds.append(r.kind); firsts.append(r.samples[0]) }
        XCTAssertEqual(kinds, [.normal, .normal, .concealed, .normal, .normal])
        XCTAssertEqual(firsts[0], 1000); XCTAssertEqual(firsts[1], 1001)
        XCTAssertEqual(firsts[3], 1003); XCTAssertEqual(firsts[4], 1004)
        // The concealed frame repeats the previous one, quieter.
        XCTAssertGreaterThan(firsts[2], 0)
        XCTAssertLessThan(firsts[2], 1001)
        XCTAssertEqual(j.stats.lost, 1)
    }

    func testLateFramesAreDroppedAndDuplicatesIgnored() {
        var j = JitterBuffer()
        push(&j, [0, 1, 3, 4])
        _ = j.pop(); _ = j.pop()
        XCTAssertEqual(j.pop().kind, .concealed)                       // 2 is lost
        push(&j, [2])                                                  // and now it shows up: too late
        XCTAssertEqual(j.stats.late, 1)
        push(&j, [4])
        XCTAssertEqual(j.stats.duplicate, 1)
        XCTAssertEqual(j.pop().samples[0], 1003)
        XCTAssertEqual(j.pop().samples[0], 1004)
        XCTAssertEqual(j.stats.received, 6)
    }

    func testConcealmentFadesToSilence() {
        var j = JitterBuffer()
        push(&j, [0, 1, 2, 10, 11, 12])
        _ = j.pop(); _ = j.pop(); _ = j.pop()
        var levels: [Int16] = []
        for _ in 0..<8 { levels.append(j.pop().samples[0]) }            // 3..9 are lost, then 10 plays
        XCTAssertEqual(levels.last, 1010)
        XCTAssertGreaterThan(levels[0], levels[1])
        XCTAssertEqual(levels[3], 0)
        XCTAssertEqual(j.stats.lost, 7)
    }

    func testUnderrunBuffersAgainAndSkipsTheGap() {
        var j = JitterBuffer()
        push(&j, [0, 1, 2])
        for _ in 0..<3 { XCTAssertEqual(j.pop().kind, .normal) }
        XCTAssertEqual(j.pop().kind, .concealed)                       // nothing left
        XCTAssertEqual(j.stats.underruns, 1)
        XCTAssertEqual(j.pop().kind, .buffering)
        push(&j, [20, 21, 22])                                         // the sender carried on while we waited
        XCTAssertEqual(j.pop().samples[0], 1020)                       // no pretending 3..19 are coming
    }

    func testRunawayDepthIsTrimmedFromTheFront() {
        var j = JitterBuffer(targetFrames: 3, maxFrames: 6)
        push(&j, Array(0..<12))
        XCTAssertLessThanOrEqual(j.depth, 6)
        XCTAssertEqual(j.stats.overflow, 6)
        XCTAssertEqual(j.pop().samples[0], 1006)                       // oldest frames went, newest stay
    }

    func testSenderRestartResyncs() {
        var j = JitterBuffer()
        push(&j, [5000, 5001, 5002])
        _ = j.pop()
        push(&j, [0, 1, 2])
        XCTAssertEqual(j.stats.resyncs, 1)
        XCTAssertEqual(j.pop().samples[0], 1000)
    }

    func testSequenceWraparound() {
        var j = JitterBuffer()
        let seqs: [UInt32] = [UInt32.max - 1, UInt32.max, 0, 1]
        for (i, s) in seqs.enumerated() { j.push(seq: s, frame: f(Int16(10 + i))) }
        var out: [Int16] = []
        for _ in 0..<4 { out.append(j.pop().samples[0]) }
        XCTAssertEqual(out, [10, 11, 12, 13])
        XCTAssertEqual(j.stats.late, 0)
    }
}

final class ResamplerTests: XCTestCase {
    private func sine(_ hz: Double, rate: Double, seconds: Double, amp: Float = 0.5) -> [Float] {
        (0..<Int(rate * seconds)).map { amp * Float(sin(2 * Double.pi * hz * Double($0) / rate)) }
    }
    private func peak(_ x: ArraySlice<Float>) -> Float { x.map(abs).max() ?? 0 }
    private func crossings(_ x: [Float]) -> Int { zip(x, x.dropFirst()).filter { $0.0 < 0 && $0.1 >= 0 }.count }

    func testDownsampleKeepsToneAndAmplitude() {
        let r = StreamResampler(inRate: 48_000, outRate: 16_000)
        let out = r.process(sine(440, rate: 48_000, seconds: 1))
        XCTAssertEqual(Double(out.count), 16_000, accuracy: 40)
        XCTAssertEqual(peak(out[200...]), 0.5, accuracy: 0.02)
        XCTAssertEqual(crossings(Array(out)), 440, accuracy: 3)
    }

    func testUpsampleKeepsToneAndAmplitude() {
        let r = StreamResampler(inRate: 16_000, outRate: 48_000)
        let out = r.process(sine(1000, rate: 16_000, seconds: 1))
        XCTAssertEqual(Double(out.count), 48_000, accuracy: 120)
        XCTAssertEqual(peak(out[300...]), 0.5, accuracy: 0.02)
        XCTAssertEqual(crossings(Array(out)), 1000, accuracy: 4)
    }

    func testNonIntegerRatio() {
        let r = StreamResampler(inRate: 44_100, outRate: 16_000)
        let out = r.process(sine(300, rate: 44_100, seconds: 1))
        XCTAssertEqual(Double(out.count), 16_000, accuracy: 40)
        XCTAssertEqual(peak(out[200...]), 0.5, accuracy: 0.02)
    }

    func testToneAboveTheNewNyquistIsRemoved() {
        let r = StreamResampler(inRate: 48_000, outRate: 16_000)
        let out = r.process(sine(12_000, rate: 48_000, seconds: 0.5))      // 12 kHz would alias into 16 kHz audio
        XCTAssertLessThan(peak(out[100...]), 0.05)
    }

    func testChunkSizeDoesNotChangeTheOutput() {
        let input = sine(523, rate: 48_000, seconds: 0.3)
        let whole = StreamResampler(inRate: 48_000, outRate: 16_000).process(input)
        let chunked = StreamResampler(inRate: 48_000, outRate: 16_000)
        var parts: [Float] = []
        var i = 0
        for n in [1, 7, 100, 333, 960, 3, 2048].cycled(until: input.count) { parts += chunked.process(Array(input[i..<min(input.count, i + n)])); i += n; if i >= input.count { break } }
        XCTAssertEqual(parts.count, whole.count)
        for (a, b) in zip(parts, whole) { XCTAssertEqual(a, b, accuracy: 1e-5) }
    }

    func testSilenceStaysSilentAndConstantStaysConstant() {
        let r = StreamResampler(inRate: 48_000, outRate: 16_000)
        XCTAssertEqual(peak(r.process([Float](repeating: 0, count: 4800))[...]), 0)
        let dc = StreamResampler(inRate: 16_000, outRate: 44_100).process([Float](repeating: 0.25, count: 3200))
        XCTAssertEqual(dc[100], 0.25, accuracy: 0.002)
    }

    func testFifoDropsOldestAndZeroFillsShortReads() {
        var q = FloatFIFO(capacity: 4)
        q.append([1, 2, 3])
        var out = [Float](repeating: 9, count: 5)
        XCTAssertEqual(q.read(5, into: &out), 3)
        XCTAssertEqual(out, [1, 2, 3, 0, 0])
        q.append([1, 2, 3, 4, 5, 6])
        XCTAssertEqual(q.count, 4)
        var two = [Float](repeating: 0, count: 2)
        q.read(2, into: &two)
        XCTAssertEqual(two, [3, 4])
    }
}

private extension Array where Element == Int {
    func cycled(until total: Int) -> [Int] { var out: [Int] = []; var sum = 0; while sum < total { for x in self { out.append(x); sum += x } }; return out }
}

/// An encrypted UDP sender talking to a real `AudioLink` over loopback.
final class AudioLinkLoopbackTests: XCTestCase {
    private let key = MydroidCrypto.randomBytes(32)

    private final class Sender {
        let fd: Int32
        let cipher: AudioPacketCipher
        let up: AudioPacketCipher
        var dest = sockaddr_in()
        init(key: Data, port: UInt16) {
            let s = socket(AF_INET, SOCK_DGRAM, 0)
            var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
            a.sin_addr.s_addr = inet_addr("127.0.0.1")
            _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            var tv = timeval(tv_sec: 0, tv_usec: 300_000)
            setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            a.sin_port = port.bigEndian
            fd = s
            dest = a
            cipher = AudioPacketCipher(key: AudioCrypto.downKey(key))
            up = AudioPacketCipher(key: AudioCrypto.upKey(key))
        }
        deinit { close(fd) }
        func raw(_ d: Data) {
            _ = d.withUnsafeBytes { p in withUnsafePointer(to: &dest) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, p.baseAddress, p.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
        }
        func send(seq: UInt32, value: Int16) {
            raw(try! cipher.seal(seq: seq, frame: PCM.data(from: [Int16](repeating: value, count: CallAudioFormat.frameSamples))))
        }
        func receiveUplink() -> (seq: UInt32, frame: Data)? {
            var buf = [UInt8](repeating: 0, count: 2048)
            let n = recv(fd, &buf, buf.count, 0)
            guard n > 0 else { return nil }
            return try? up.open(Data(buf[0..<n]))
        }
    }

    private func waitFor(_ cond: () -> Bool, timeout: TimeInterval = 2) {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
    }

    func testOrderLossAndLateDropsOverRealUDP() throws {
        let link = try AudioLink(key: key)
        link.start()
        defer { link.stop() }
        XCTAssertGreaterThan(link.port, 0)
        let tx = Sender(key: key, port: link.port)

        // Sent: 0, 1, 3, 2 (swapped), 5, 6. Frame 4 is never sent. Plus two bad packets, and later a stale frame 1.
        for s: UInt32 in [0, 1, 3, 2, 5, 6] { tx.send(seq: s, value: Int16(s) + 100) }
        tx.raw(Data(repeating: 7, count: CallAudioFormat.packetBytes))             // authentic length, wrong tag
        tx.raw(Data([1, 2, 3]))                                                     // too short
        waitFor { link.stats.jitter.received == 6 && link.stats.rejected == 2 }
        XCTAssertEqual(link.stats.jitter.received, 6)
        XCTAssertEqual(link.stats.rejected, 2)

        var kinds: [JitterBuffer.Kind] = [], firsts: [Int16] = []
        for _ in 0..<6 { let r = link.pullFrame(); kinds.append(r.kind); firsts.append(r.samples[0]) }
        XCTAssertEqual(kinds, [.normal, .normal, .normal, .normal, .concealed, .normal])
        XCTAssertEqual(Array(firsts[0..<4]), [100, 101, 102, 103])                 // the swap was put right
        XCTAssertEqual(firsts[5], 105)                                              // 4 was concealed, 5 still plays on time
        XCTAssertEqual(link.stats.jitter.lost, 1)

        tx.send(seq: 1, value: 999)                                                 // long past: dropped
        waitFor { link.stats.jitter.late == 1 }
        XCTAssertEqual(link.stats.jitter.late, 1)
    }

    func testUplinkGoesBackToTheDownlinkSourceAndOnlyWhenAuthenticated() throws {
        let link = try AudioLink(key: key)
        link.start()
        defer { link.stop() }
        let tx = Sender(key: key, port: link.port)
        let frame = [Int16](repeating: 321, count: CallAudioFormat.frameSamples)

        XCTAssertFalse(link.send(frame: frame), "nowhere to send yet")
        tx.raw(Data(repeating: 1, count: CallAudioFormat.packetBytes))             // junk must not become the peer
        waitFor { link.stats.rejected == 1 }
        XCTAssertFalse(link.hasPeer)
        XCTAssertFalse(link.send(frame: frame))

        tx.send(seq: 0, value: 1)
        waitFor { link.hasPeer }
        XCTAssertTrue(link.hasPeer)
        XCTAssertFalse(link.send(frame: [1, 2, 3]), "wrong frame size")
        XCTAssertTrue(link.send(frame: frame))
        XCTAssertTrue(link.send(frame: frame))
        let a = try XCTUnwrap(tx.receiveUplink()), b = try XCTUnwrap(tx.receiveUplink())
        XCTAssertEqual(PCM.samples(from: a.frame), frame)
        XCTAssertEqual(b.seq, a.seq &+ 1)
        XCTAssertEqual(link.stats.sent, 2)
    }

    func testSteadyStreamAtTwentyMillisecondPacing() throws {
        let link = try AudioLink(key: key)
        link.start()
        defer { link.stop() }
        let tx = Sender(key: key, port: link.port)
        // A frame every 20 ms in real time, each played as it comes due.
        var played = 0, last: Int16 = 0
        for s in 1...40 {
            tx.send(seq: UInt32(s), value: Int16(s))
            Thread.sleep(forTimeInterval: 0.02)
            waitFor { link.stats.jitter.received >= s }
            let r = link.pullFrame()
            if r.kind == .normal {
                if last != 0 { XCTAssertEqual(r.samples[0], last + 1) }
                last = r.samples[0]; played += 1
            }
        }
        XCTAssertEqual(played, 38)                                                   // the first two pulls were still filling the 60 ms buffer
        XCTAssertEqual(link.stats.jitter.lost, 0)
        XCTAssertEqual(link.stats.jitter.underruns, 0)
        XCTAssertGreaterThan(link.stats.rxLevel, 0)
    }
}

final class AdbSupportTests: XCTestCase {
    func testMdnsParsing() {
        let out = """
        List of discovered mdns services
        adb-9A3B2C-xYz7Qk\t_adb-tls-connect._tcp.\t192.168.1.23:41235
        mydroid-k3m9p2qr\t_adb-tls-pairing._tcp.\t192.168.1.23:37891
        garbage line
        weird\t_adb._tcp.\t192.168.1.9:5555
        """
        let s = AdbParsing.mdnsServices(out)
        XCTAssertEqual(s.count, 3)
        XCTAssertTrue(s[0].isConnect); XCTAssertEqual(s[0].endpoint, "192.168.1.23:41235"); XCTAssertEqual(s[0].type, "_adb-tls-connect._tcp")
        XCTAssertTrue(s[1].isPairing); XCTAssertEqual(s[1].name, "mydroid-k3m9p2qr"); XCTAssertEqual(s[1].port, 37891)
        XCTAssertFalse(s[2].isConnect || s[2].isPairing)
        XCTAssertEqual(AdbParsing.mdnsServices("List of discovered mdns services\n").count, 0)
    }

    func testPairAndConnectAndDevices() {
        XCTAssertTrue(AdbParsing.pairSucceeded("Successfully paired to 192.168.1.23:37891 [guid=adb-9A3B2C-xYz7Qk]"))
        XCTAssertFalse(AdbParsing.pairSucceeded("Failed: Wrong password or connection was dropped"))
        XCTAssertTrue(AdbParsing.connectSucceeded("connected to 192.168.1.23:41235"))
        XCTAssertTrue(AdbParsing.connectSucceeded("already connected to 192.168.1.23:41235"))
        XCTAssertFalse(AdbParsing.connectSucceeded("failed to connect to '192.168.1.23:41235': Connection refused"))
        XCTAssertFalse(AdbParsing.connectSucceeded("cannot connect to 192.168.1.23:41235: Connection refused (61)"))
        let d = AdbParsing.devices("List of devices attached\n192.168.1.23:41235\tdevice\nemulator-5554\toffline\nadb-x (2)._adb-tls-connect._tcp\tdevice\n")
        XCTAssertEqual(d, [
            .init(serial: "192.168.1.23:41235", state: "device"),
            .init(serial: "emulator-5554", state: "offline"),
            .init(serial: "adb-x (2)._adb-tls-connect._tcp", state: "device"),
        ])
    }

    func testQrPayloadAndRandomNames() {
        XCTAssertEqual(AdbPairing.qrPayload(service: "mydroid-abc", password: "pw12"), "WIFI:T:ADB;S:mydroid-abc;P:pw12;;")
        XCTAssertEqual(AdbPairing.qrPayload(service: "a;b", password: "x"), "WIFI:T:ADB;S:a\\;b;P:x;;")
        let a = AdbPairing.randomServiceName(), b = AdbPairing.randomServiceName()
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasPrefix("mydroid-")); XCTAssertEqual(a.count, 16)
        XCTAssertEqual(AdbPairing.randomPassword().count, 12)
        XCTAssertFalse(AdbPairing.randomPassword().contains(";"))
    }

    func testHelperLines() throws {
        XCTAssertEqual(HelperProtocol.parse(line: #"{"ev":"tier","tier":"full"}"#), .tier(.full))
        XCTAssertEqual(HelperProtocol.parse(line: #"{"ev":"tier","tier":"listen"}"#), .tier(.listen))
        XCTAssertEqual(HelperProtocol.parse(line: #"{"ev":"call","inCall":true}"#), .call(inCall: true))
        XCTAssertEqual(HelperProtocol.parse(line: #"{"ev":"routed","to":"mac"}"#), .routed(to: .mac, error: nil))
        XCTAssertEqual(HelperProtocol.parse(line: #"{"ev":"routed","to":"phone","error":"no access"}"#), .routed(to: .phone, error: "no access"))
        XCTAssertEqual(HelperProtocol.parse(line: #"{"ev":"stats","rxRms":0.25,"txRms":0.1,"lost":3}"#), .stats(rxRms: 0.25, txRms: 0.1, lost: 3))
        XCTAssertNil(HelperProtocol.parse(line: "WARNING: linker: something"))
        XCTAssertNil(HelperProtocol.parse(line: #"{"ev":"tier","tier":"bogus"}"#))
        XCTAssertNil(HelperProtocol.parse(line: #"{"ev":"future"}"#))

        let key = Data(repeating: 9, count: 32)
        let hello = HelperProtocol.hello(macHost: "192.168.1.5", udpPort: 50123, key: key)
        XCTAssertTrue(hello.hasSuffix("\n"))
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(hello.utf8)) as? [String: Any])
        XCTAssertEqual(o["cmd"] as? String, "hello"); XCTAssertEqual(o["macHost"] as? String, "192.168.1.5")
        XCTAssertEqual(o["udpPort"] as? Int, 50123); XCTAssertEqual(Data(base64Encoded: o["key"] as! String), key)
        XCTAssertEqual(HelperProtocol.route(to: .mac), "{\"cmd\":\"route\",\"to\":\"mac\"}\n")
        XCTAssertEqual(HelperProtocol.quit, "{\"cmd\":\"quit\"}\n")
    }

    func testLineBufferHandlesChunks() {
        var b = LineBuffer()
        XCTAssertEqual(b.append(Data("{\"ev\":\"ca".utf8)), [])
        XCTAssertEqual(b.append(Data("ll\",\"inCall\":true}\nnoise\n{\"ev".utf8)), ["{\"ev\":\"call\",\"inCall\":true}", "noise"])
        XCTAssertEqual(b.append(Data("\":\"x\"}\n".utf8)), ["{\"ev\":\"x\"}"])
    }

    func testBackoffDoublesToItsCap() {
        var b = Backoff(base: 1, cap: 30)
        XCTAssertEqual([b.next(), b.next(), b.next(), b.next(), b.next(), b.next(), b.next()], [1, 2, 4, 8, 16, 30, 30])
        b.reset()
        XCTAssertEqual(b.next(), 1)
    }

    func testLocalAddressReachingLoopbackAndSettingsWire() {
        XCTAssertEqual(LocalAddress.reaching(host: "127.0.0.1"), "127.0.0.1")
        XCTAssertEqual(SyncSettings().wireFields["callAudio"] as? Bool, false)
        var s = SyncSettings(); s.callAudio = true
        XCTAssertEqual(s.wireFields["callAudio"] as? Bool, true)
        let old = Data(#"{"notifications":true,"photos":true,"calls":true,"clipboard":false}"#.utf8)
        XCTAssertEqual(try? JSONDecoder().decode(SyncSettings.self, from: old).callAudio, false)
        XCTAssertEqual(FixKind.devoptions.rawValue, "devoptions")
        XCTAssertTrue(CallAudioTier.full.canTalk); XCTAssertFalse(CallAudioTier.listen.canTalk); XCTAssertFalse(CallAudioTier.none.canRoute)
    }
}

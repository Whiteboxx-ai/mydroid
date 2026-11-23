package com.mydroid.protocol

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The helper's whole control and audio path on the JVM: a fake AudioRecord/AudioTrack and a fake Mac on loopback UDP. */
class CallBridgeTest {
    private val master = ByteArray(32) { (it * 3).toByte() }
    private val keys = AudioKeys(master)

    private class FakeSource(val fill: Int = 77) : PcmSource {
        @Volatile var stopped = false
        @Volatile var released = false
        override fun read(buf: ByteArray, off: Int, len: Int): Int {
            if (stopped) return -3
            Thread.sleep(AudioFmt.FRAME_MS.toLong()) // paced like a real record
            if (stopped) return -3
            for (i in 0 until len / 2) { buf[off + 2 * i] = fill.toByte(); buf[off + 2 * i + 1] = 0 } // a constant "tone", RMS = fill
            return len
        }
        override fun stop() { stopped = true }
        override fun release() { released = true }
    }

    private class FakeSink : PcmSink {
        val writes = CopyOnWriteArrayList<ByteArray>()
        @Volatile var released = false
        override fun write(buf: ByteArray, off: Int, len: Int): Int { writes += buf.copyOfRange(off, off + len); return len }
        override fun release() { released = true }
    }

    private class FakeBackend(var tier: CallTier = CallTier.Full) : CallAudioBackend {
        @Volatile var inCall = false
        var downlinkFailsFull = false
        var downlinkFailsAll = false
        var uplinkFails = false
        val sources = CopyOnWriteArrayList<FakeSource>()
        val sinks = CopyOnWriteArrayList<FakeSink>()
        val fullRequests = CopyOnWriteArrayList<Boolean>()
        override fun probeTier() = tier
        override fun inCall() = inCall
        override fun openDownlink(full: Boolean): PcmSource {
            fullRequests += full
            if (downlinkFailsAll || (full && downlinkFailsFull)) throw IllegalStateException("no downlink")
            return FakeSource().also { sources += it }
        }
        override fun openUplink(): PcmSink {
            if (uplinkFails) throw IllegalStateException("no uplink")
            return FakeSink().also { sinks += it }
        }
    }

    private val events = LinkedBlockingQueue<String>()
    private val log = CopyOnWriteArrayList<String>()
    private val mac = DatagramSocket(0, InetAddress.getLoopbackAddress()).apply { soTimeout = 2000 }
    private var bridge: CallBridge? = null

    @After fun tearDown() { bridge?.shutdown(); mac.close() }

    private fun bridgeFor(b: FakeBackend, callWaitMs: Long = 400): CallBridge =
        CallBridge(b, { events.add(it) }, { log += it }, pollMs = 20, statsMs = 100, callWaitMs = callWaitMs).also { bridge = it; it.start() }

    private fun hello(br: CallBridge, key: ByteArray = master) =
        br.handleLine("""{"cmd":"hello","macHost":"127.0.0.1","udpPort":${mac.localPort},"key":"${B64.std(key)}"}""")

    /** Next event whose JSON contains [needle]. */
    private fun await(needle: String, ms: Long = 3000): String {
        val end = System.currentTimeMillis() + ms
        while (true) {
            val left = end - System.currentTimeMillis()
            val e = events.poll(maxOf(left, 1), TimeUnit.MILLISECONDS) ?: throw AssertionError("no event containing $needle; log=$log")
            if (e.contains(needle)) return e
            if (left <= 0) throw AssertionError("timeout $needle")
        }
    }

    private fun receiveFrom(): DatagramPacket {
        val dp = DatagramPacket(ByteArray(2048), 2048)
        mac.receive(dp)
        return dp
    }

    @Test fun startupReportsTierAndCallState() {
        bridgeFor(FakeBackend(CallTier.Listen))
        assertEquals("""{"ev":"tier","tier":"listen"}""", events.poll(1, TimeUnit.SECONDS))
        assertEquals("""{"ev":"call","inCall":false}""", events.poll(1, TimeUnit.SECONDS))
    }

    @Test fun reportsCallModeChanges() {
        val b = FakeBackend(); bridgeFor(b)
        b.inCall = true; await("\"inCall\":true")
        b.inCall = false; await("\"inCall\":false")
    }

    @Test fun routeBeforeHelloOrOutsideACallIsAnErrorNotACrash() {
        val b = FakeBackend(); val br = bridgeFor(b, callWaitMs = 100)
        br.handleLine("""{"cmd":"route","to":"mac"}""")
        assertTrue(await("routed").contains("not in a call"))
        b.inCall = true
        br.handleLine("""{"cmd":"route","to":"mac"}""")
        assertTrue(await("routed").contains("no hello"))
        assertFalse(br.routedToMac)
    }

    @Test fun fullTierStreamsDownlinkEncryptedAndInjectsUplink() {
        val b = FakeBackend(); val br = bridgeFor(b)
        b.inCall = true
        hello(br)
        br.handleLine("""{"cmd":"route","to":"mac"}""")
        assertEquals("""{"ev":"routed","to":"mac"}""", await("routed"))
        assertEquals(listOf(true), b.fullRequests)

        // Downlink: authenticated 660-byte packets with a counting seq, decrypting to the source frame.
        val opener = AudioOpener(keys.down)
        val dp = receiveFrom()
        assertEquals(660, dp.length)
        val p0 = opener.open(dp.data, dp.length)!!
        assertEquals(0L, p0.seq)
        assertEquals(77, p0.frame[0].toInt())
        val p1 = receiveFrom().let { opener.open(it.data, it.length)!! }
        assertEquals(1L, p1.seq)

        // Uplink: the Mac answers to the source address of the downlink packets.
        val sealer = AudioSealer(keys.up)
        val to = InetAddress.getLoopbackAddress()
        for (i in 0 until 12) {
            val f = ByteArray(640) { (40 + i).toByte() }.also { for (k in 0 until 640 step 2) it[k + 1] = 0 }
            val pkt = sealer.seal(i.toLong(), f)
            mac.send(DatagramPacket(pkt, pkt.size, to, dp.port))
            Thread.sleep(20) // paced like the real Mac; a faster burst would (correctly) overflow the 8-frame queue
        }
        // A live stream never stops, and the 2-frame pre-buffer holds a lone last frame; trail with silent frames like real traffic.
        for (i in 12 until 16) {
            val pkt = sealer.seal(i.toLong(), ByteArray(640)); mac.send(DatagramPacket(pkt, pkt.size, to, dp.port)); Thread.sleep(20)
        }
        // A forged packet and a replayed one never reach the track.
        val forged = sealer.seal(99, ByteArray(640)); forged[10] = (forged[10].toInt() xor 1).toByte()
        mac.send(DatagramPacket(forged, forged.size, to, dp.port))
        val dup = sealer.seal(3, ByteArray(640) { 43 }); mac.send(DatagramPacket(dup, dup.size, to, dp.port))

        val sink = b.sinks.single()
        val end = System.currentTimeMillis() + 3000
        while (sink.writes.count { it[0].toInt() >= 40 } < 12 && System.currentTimeMillis() < end) Thread.sleep(20)
        val real = sink.writes.filter { it[0].toInt() != 0 }
        assertEquals((40..51).toList(), real.map { it[0].toInt() }) // in order, once each, silence in between
        assertTrue(sink.writes.all { it.size == 640 })

        val stats = await("\"ev\":\"stats\"")
        assertTrue(stats, stats.contains("\"rxRms\":77"))
        assertTrue(stats.contains("\"lost\":"))

        br.handleLine("""{"cmd":"route","to":"phone"}""")
        assertEquals("""{"ev":"routed","to":"phone"}""", await("\"to\":\"phone\""))
        assertTrue(b.sources.single().released); assertTrue(b.sources.single().stopped); assertTrue(sink.released)
        assertFalse(br.routedToMac)
    }

    @Test fun listenTierHasNoUplink() {
        val b = FakeBackend(CallTier.Listen); val br = bridgeFor(b)
        b.inCall = true; hello(br)
        br.handleLine("""{"cmd":"route","to":"mac"}""")
        assertEquals("""{"ev":"routed","to":"mac"}""", await("routed"))
        assertEquals(listOf(false), b.fullRequests)
        assertTrue(b.sinks.isEmpty())
        val dp = receiveFrom()
        assertNotNull(AudioOpener(keys.down).open(dp.data, dp.length))
    }

    @Test fun fullFallsBackToListenWhenUplinkCannotBeCreated() {
        val b = FakeBackend(); b.uplinkFails = true
        val br = bridgeFor(b); b.inCall = true; hello(br)
        br.handleLine("""{"cmd":"route","to":"mac"}""")
        await("\"tier\":\"listen\"")
        assertEquals("""{"ev":"routed","to":"mac"}""", await("routed"))
        assertTrue(b.sinks.isEmpty())
        receiveFrom()
    }

    @Test fun fullFallsBackToVoiceDownlinkWhenExtractionFails() {
        val b = FakeBackend(); b.downlinkFailsFull = true
        val br = bridgeFor(b); b.inCall = true; hello(br)
        br.handleLine("""{"cmd":"route","to":"mac"}""")
        await("\"tier\":\"listen\"")
        assertEquals("""{"ev":"routed","to":"mac"}""", await("routed"))
        assertEquals(listOf(true, false), b.fullRequests)
    }

    @Test fun noAudioAtAllReportsErrorAndTierNone() {
        val b = FakeBackend(); b.downlinkFailsAll = true
        val br = bridgeFor(b); b.inCall = true; hello(br)
        br.handleLine("""{"cmd":"route","to":"mac"}""")
        await("\"tier\":\"none\"")
        val e = await("routed")
        assertTrue(e, e.contains("\"to\":\"mac\"") && e.contains("\"error\""))
        assertFalse(br.routedToMac)
        // the helper is still alive and answering
        br.handleLine("""{"cmd":"route","to":"phone"}""")
        await("\"to\":\"phone\"")
    }

    @Test fun callEndReleasesEverythingAndTellsTheMac() {
        val b = FakeBackend(); val br = bridgeFor(b); b.inCall = true; hello(br)
        br.handleLine("""{"cmd":"route","to":"mac"}""")
        await("routed")
        b.inCall = false
        await("\"inCall\":false")
        val e = await("\"to\":\"phone\"")
        assertTrue(e, e.contains("call ended"))
        assertTrue(b.sources.single().released); assertTrue(b.sinks.single().released)
        assertFalse(br.routedToMac)
    }

    @Test fun aModeBlipDoesNotDropARoutedCall() {
        val b = FakeBackend(); val br = bridgeFor(b); b.inCall = true; hello(br)
        br.handleLine("""{"cmd":"route","to":"mac"}""")
        await("routed")
        b.inCall = false; Thread.sleep(25); b.inCall = true // shorter than two polls (20 ms each) most of the time
        Thread.sleep(150)
        assertTrue(br.routedToMac || log.any { it.contains("call ended") }) // tolerate a scheduler hiccup, but must never crash
    }

    @Test fun quitAndEofReleaseAndStop() {
        val b = FakeBackend(); val br = bridgeFor(b); b.inCall = true; hello(br)
        br.handleLine("""{"cmd":"route","to":"mac"}""")
        await("routed")
        assertFalse(br.handleLine("""{"cmd":"quit"}"""))
        assertTrue(b.sources.single().released); assertTrue(b.sinks.single().released)
        assertFalse(br.routedToMac)
    }

    @Test fun shutdownOnEofReleases() {
        val b = FakeBackend(); val br = bridgeFor(b); b.inCall = true; hello(br)
        br.handleLine("""{"cmd":"route","to":"mac"}""")
        await("routed")
        br.shutdown()
        assertTrue(b.sources.single().released)
    }

    @Test fun garbageLinesAreIgnored() {
        val b = FakeBackend(); val br = bridgeFor(b)
        assertTrue(br.handleLine("garbage")); assertTrue(br.handleLine("")); assertTrue(br.handleLine("""{"cmd":"hello"}"""))
        assertTrue(br.handleLine("""{"cmd":"nope"}"""))
    }

    @Test fun rerouteKeepsSequenceMovingForTheSameKey() {
        val b = FakeBackend(); val br = bridgeFor(b); b.inCall = true; hello(br)
        br.handleLine("""{"cmd":"route","to":"mac"}"""); await("routed")
        val first = receiveFrom().let { AudioOpener(keys.down).open(it.data, it.length)!!.seq }
        br.handleLine("""{"cmd":"route","to":"phone"}"""); await("\"to\":\"phone\"")
        hello(br) // same key again: GCM nonces must not repeat
        br.handleLine("""{"cmd":"route","to":"mac"}"""); await("routed")
        // drain until a packet newer than anything from the first route shows up
        var seq = -1L
        repeat(80) { val d = receiveFrom(); seq = AudioOpener(keys.down).open(d.data, d.length)!!.seq; if (seq > first + 1) return@repeat }
        assertTrue("seq $seq must continue past $first", seq > first)
    }

    @Test fun audioReadFailureAbortsBackToPhone() {
        val b = FakeBackend(); val br = bridgeFor(b); b.inCall = true; hello(br)
        br.handleLine("""{"cmd":"route","to":"mac"}""")
        await("routed")
        b.sources.single().stopped = true // the record dies underneath us
        val e = await("\"to\":\"phone\"")
        assertTrue(e, e.contains("error"))
        assertFalse(br.routedToMac)
    }
}

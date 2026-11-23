package com.mydroid.protocol

import java.security.MessageDigest
import org.junit.Test
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue

class CallAudioTest {
    private val master = ByteArray(32) { it.toByte() }
    private fun frame(fill: Int) = ByteArray(AudioFmt.FRAME_BYTES) { fill.toByte() }

    // ------------------------------------------------------------ keys and packets

    @Test fun directionKeysMatchIndependentHkdf() {
        val k = AudioKeys(master)
        // Computed with a from-scratch Python HKDF-SHA256 (empty salt) and with CryptoKit on the Mac.
        assertEquals("9ee4e7624ef403a6c9d1b37ae205a5271e2fece658f5dea8f5625962a6fa8f84", Hex.encode(k.down))
        assertEquals("9d154efcb8e153b302bec7530aa526025adc00cb9c72b0ac7e393dd3c36191a1", Hex.encode(k.up))
    }

    @Test fun packetMatchesCryptoKitVector() {
        // Produced by CryptoKit (AES.GCM, nonce 0000 || u64 BE seq) on the Mac side's toolchain.
        val frame = ByteArray(640) { ((it * 7) and 0xff).toByte() }
        val pkt = AudioSealer(AudioKeys(master).down).seal(7, frame)
        assertEquals(660, pkt.size)
        val hex = Hex.encode(pkt)
        assertEquals("00000007dc98c2173369d5688aec638b916493ca", hex.take(40))
        assertEquals("8f6205c05a57fb0eb2759d7b4a63cd32e8281f79", hex.takeLast(40))
        assertEquals("6998d63081cd233d345e320d1100647100cd5628f632bd1d1c2376e76099a799", Hex.encode(MessageDigest.getInstance("SHA-256").digest(pkt)))
        val back = AudioOpener(AudioKeys(master).down).open(pkt)!!
        assertEquals(7L, back.seq)
        assertArrayEquals(frame, back.frame)
    }

    @Test fun seqIsBigEndianAndFullU32() {
        val k = AudioKeys(master)
        val s = AudioSealer(k.up); val o = AudioOpener(k.up)
        val pkt = s.seal(0xFFFF_FFFEL, frame(3))
        assertEquals(listOf(0xff, 0xff, 0xff, 0xfe), (0..3).map { pkt[it].toInt() and 0xff })
        assertEquals(0xFFFF_FFFEL, o.open(pkt)!!.seq)
    }

    @Test fun directionsCannotBeCrossed() {
        val k = AudioKeys(master)
        val pkt = AudioSealer(k.down).seal(1, frame(9))
        assertNull(AudioOpener(k.up).open(pkt))
        assertNotNull(AudioOpener(k.down).open(pkt))
    }

    @Test fun tamperingShortAndLongPacketsAreRejected() {
        val k = AudioKeys(master)
        val o = AudioOpener(k.down)
        val pkt = AudioSealer(k.down).seal(5, frame(1))
        for (i in listOf(0, 3, 4, 100, 659)) { // seq, ciphertext, tag
            val bad = pkt.copyOf(); bad[i] = (bad[i].toInt() xor 1).toByte()
            assertNull("byte $i", o.open(bad))
        }
        assertNull(o.open(pkt, 659))
        assertNull(o.open(pkt.copyOf(661), 661))
        assertNull(o.open(ByteArray(4)))
        assertNotNull(o.open(pkt)) // the opener survives failures
    }

    @Test fun differentSeqGivesDifferentCiphertext() {
        val s = AudioSealer(AudioKeys(master).down)
        assertFalse(s.seal(1, frame(0)).contentEquals(s.seal(2, frame(0))))
    }

    @Test fun replayWindow() {
        val w = ReplayWindow()
        assertTrue(w.accept(10)); assertFalse(w.accept(10))
        assertTrue(w.accept(12)); assertTrue(w.accept(11)); assertFalse(w.accept(11)) // reorder is fine, once
        assertTrue(w.accept(200)); assertFalse(w.accept(12)) // too old
        assertTrue(w.accept(199)); assertFalse(w.accept(199)); assertFalse(w.accept(200))
        assertTrue(w.accept(0xFFFF_FFFFL))
    }

    @Test fun rmsOfKnownSignal() {
        val b = ByteArray(8)
        for (i in 0 until 4) { val v = if (i % 2 == 0) 1000 else -1000; b[2 * i] = v.toByte(); b[2 * i + 1] = (v shr 8).toByte() }
        assertEquals(1000.0, AudioFmt.rms(b, 0, 8), 0.001)
        assertEquals(0.0, AudioFmt.rms(ByteArray(640), 0, 640), 0.0)
    }

    // ------------------------------------------------------------ playout queue

    @Test fun queuePrebuffersThenPlaysInOrder() {
        val q = PlayoutQueue(prefill = 2)
        q.push(1, frame(1))
        assertNull(q.pop()) // still pre-buffering
        q.push(0, frame(0)) // arrived out of order
        assertEquals(0, q.pop()!![0].toInt()); assertEquals(1, q.pop()!![0].toInt())
        assertNull(q.pop()) // starved
        assertEquals(1L, q.underruns)
        assertEquals(0L, q.lost)
    }

    @Test fun missingFrameBecomesSilenceNotATimeShift() {
        val q = PlayoutQueue(prefill = 2)
        q.push(10, frame(1)); q.push(12, frame(3)); q.push(13, frame(4))
        assertEquals(1, q.pop()!![0].toInt())
        assertNull(q.pop()) // slot 11 never came
        assertEquals(3, q.pop()!![0].toInt()); assertEquals(4, q.pop()!![0].toInt())
        assertEquals(1L, q.lost)
    }

    @Test fun lateFramesAreCountedAndDropped() {
        val q = PlayoutQueue(prefill = 1)
        q.push(5, frame(5)); q.pop()
        q.push(5, frame(5)); q.push(4, frame(4))
        assertEquals(2L, q.late); assertEquals(0, q.size)
    }

    @Test fun overflowDropsOldestAndBoundsLatency() {
        val q = PlayoutQueue(prefill = 2, maxFrames = 4)
        for (i in 0 until 10) q.push(i.toLong(), frame(i))
        assertEquals(4, q.size); assertEquals(6L, q.dropped)
        // 6..9 remain; the first pop resyncs to the oldest kept frame
        assertEquals(6, q.pop()!![0].toInt())
    }

    @Test fun bigGapResyncsInsteadOfPlayingSilenceForSeconds() {
        val q = PlayoutQueue(prefill = 1, maxGap = 25)
        q.push(1, frame(1)); q.pop()
        q.push(1000, frame(9))
        assertEquals(9, q.pop()!![0].toInt())
        assertTrue(q.lost >= 998)
    }

    @Test fun duplicatesAreIgnored() {
        val q = PlayoutQueue(prefill = 1)
        q.push(3, frame(1)); q.push(3, frame(2))
        assertEquals(1, q.size); assertEquals(1, q.pop()!![0].toInt())
    }

    // ------------------------------------------------------------ control lines

    @Test fun parsesHello() {
        val key = B64.std(master)
        val c = HelperControl.parse("""{"cmd":"hello","macHost":"192.168.1.5","udpPort":47900,"key":"$key"}""") as HelperCmd.Hello
        assertEquals("192.168.1.5", c.macHost); assertEquals(47900, c.udpPort); assertArrayEquals(master, c.key)
    }

    @Test fun rejectsBadHello() {
        val key = B64.std(master)
        for (line in listOf(
            """{"cmd":"hello","udpPort":1,"key":"$key"}""",
            """{"cmd":"hello","macHost":"h","udpPort":0,"key":"$key"}""",
            """{"cmd":"hello","macHost":"h","udpPort":70000,"key":"$key"}""",
            """{"cmd":"hello","macHost":"h","udpPort":9,"key":"${B64.std(ByteArray(16))}"}""",
            """{"cmd":"hello","macHost":"h","udpPort":9,"key":"!!notbase64"}""",
            """{"cmd":"hello","macHost":"h","udpPort":"9","key":"$key"}""",
        )) assertTrue(line, HelperControl.parse(line) is HelperCmd.Bad)
    }

    @Test fun parsesRouteQuitAndGarbage() {
        assertTrue((HelperControl.parse("""{"cmd":"route","to":"mac"}""") as HelperCmd.Route).toMac)
        assertFalse((HelperControl.parse("""  {"cmd":"route","to":"phone"}  """) as HelperCmd.Route).toMac)
        assertTrue(HelperControl.parse("""{"cmd":"route","to":"moon"}""") is HelperCmd.Bad)
        assertTrue(HelperControl.parse("""{"cmd":"quit"}""") === HelperCmd.Quit)
        assertTrue(HelperControl.parse("not json") is HelperCmd.Bad)
        assertTrue(HelperControl.parse("[1,2]") is HelperCmd.Bad)
        assertTrue(HelperControl.parse("""{"cmd":"dance"}""") is HelperCmd.Bad)
        assertTrue(HelperControl.parse("") is HelperCmd.Bad)
    }

    @Test fun eventsAreOneLineOfJson() {
        assertEquals("""{"ev":"tier","tier":"full"}""", HelperControl.tier(CallTier.Full))
        assertEquals("""{"ev":"call","inCall":true}""", HelperControl.call(true))
        assertEquals("""{"ev":"routed","to":"mac"}""", HelperControl.routed("mac"))
        assertEquals("""{"ev":"routed","to":"mac","error":"not in a call"}""", HelperControl.routed("mac", error = "not in a call"))
        assertEquals("""{"ev":"routed","to":"phone","reason":"call ended"}""", HelperControl.routed("phone", reason = "call ended"))
        val s = HelperControl.stats(120, 30, 2, 50, 49, 0)
        assertEquals("""{"ev":"stats","rxRms":120,"txRms":30,"lost":2,"sent":50,"recv":49,"underruns":0}""", s)
        assertFalse(s.contains('\n'))
    }
}

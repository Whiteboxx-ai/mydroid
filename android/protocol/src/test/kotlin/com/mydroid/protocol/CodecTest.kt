package com.mydroid.protocol

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

class CodecTest {
    @Test fun roundTripWithPayload() {
        val m = Message.of("xfer.chunk", ByteArray(1000) { it.toByte() }) { put("xid", "x"); put("offset", 5L) }
        val d = Codec.decode(Codec.encode(m))
        assertEquals("xfer.chunk", d.type)
        assertEquals(5L, d.long("offset"))
        assertArrayEquals(m.payload, d.payload)
    }

    @Test fun unicodeAndUnknownFields() {
        val m = Message.of("notif.posted") { put("title", "Maya Tan 😀 \"quoted\""); put("zzz", buildJsonObject { put("a", 1) }) }
        val d = Codec.decode(Codec.encode(m))
        assertEquals("Maya Tan 😀 \"quoted\"", d.str("title"))
        assertNotNull(d.obj("zzz"))
    }

    @Test fun badInputsRejected() {
        assertThrows(ProtocolException::class.java) { Codec.decode(byteArrayOf(0, 0)) }
        assertThrows(ProtocolException::class.java) { Codec.decode(byteArrayOf(0, 0, 0, 99, 1)) }
        assertThrows(ProtocolException::class.java) { Codec.decode(byteArrayOf(0, 0, 0, 2, '{'.code.toByte(), '}'.code.toByte())) }
    }

    @Test fun framingRoundTripAndLimit() {
        val out = ByteArrayOutputStream()
        Codec.writeFrame(out, byteArrayOf(9, 8, 7))
        assertArrayEquals(byteArrayOf(9, 8, 7), Codec.readFrame(ByteArrayInputStream(out.toByteArray())))
        val tooBig = byteArrayOf(0x00, 0x20, 0, 0) // 2 MiB
        assertThrows(ProtocolException::class.java) { Codec.readFrame(ByteArrayInputStream(tooBig)) }
        assertThrows(ProtocolException::class.java) { Codec.writeFrame(ByteArrayOutputStream(), ByteArray(MAX_FRAME + 1)) }
    }

    @Test fun pairingUrl() {
        val p = PairingUrl.parse("mydroid://pair?v=1&mac=abc&n=My%20Mac&s=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&a=10.0.0.2:47820,[fe80::1%25en0]:47820")!!
        assertEquals("abc", p.macId); assertEquals("My Mac", p.macName); assertEquals(32, p.secret.size)
        assertEquals(listOf(HostPort("10.0.0.2", 47820), HostPort("fe80::1%en0", 47820)), p.addresses)
        assertNull(PairingUrl.parse("https://example.com"))
        assertNull(PairingUrl.parse("mydroid://pair?v=2&mac=a&s=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"))
        assertNull(PairingUrl.parse("mydroid://pair?v=1&mac=a&s=short"))
    }

    @Test fun backoff() {
        val b = Backoff()
        assertEquals(listOf(1000L, 2000L, 4000L, 8000L, 16000L, 30000L, 30000L), List(7) { b.nextDelay() })
        b.reset(); assertEquals(1000L, b.nextDelay())
    }
}

class RichNotifCodecTest {
    @Test fun richNotifRoundTrip() {
        val m = Message.of("notif.posted") {
            put("key", "0|com.whatsapp|1"); put("pkg", "com.whatsapp"); put("app", "WhatsApp"); put("category", "message")
            put("conversation", buildJsonObject {
                put("title", "Family 👨‍👩‍👧"); put("isGroup", true); put("avatar", "AAAA")
                put("messages", buildJsonArray {
                    add(buildJsonObject { put("sender", "Maya"); put("text", "Dinner at 8?"); put("when", 1700000000000L) })
                    add(buildJsonObject { put("sender", ""); put("text", "Yes"); put("when", 1700000001000L) })
                })
            })
            put("otp", buildJsonObject { put("code", "482196"); put("source", "HDFC Bank") })
        }
        val d = Codec.decode(Codec.encode(m))
        assertEquals("message", d.str("category"))
        val conv = d.obj("conversation")!!
        assertEquals(true, conv["isGroup"]!!.jsonPrimitive.boolean)
        assertEquals(2, conv["messages"]!!.jsonArray.size)
        assertEquals("", conv["messages"]!!.jsonArray[1].jsonObject["sender"]!!.jsonPrimitive.content)
        assertEquals("482196", d.obj("otp")!!["code"]!!.jsonPrimitive.content)
    }

    @Test fun oldPeerIgnoresNewFields() {
        // A v1 receiver only reads known fields; the extra ones must not break decoding.
        val d = Codec.decode(Codec.encode(Message.of("notif.posted") { put("key", "k"); put("category", "other"); put("otp", buildJsonObject { put("code", "1") }) }))
        assertEquals("k", d.str("key"))
    }

    @Test fun heartbeatConstantsMatchSpec() {
        assertEquals(25_000L, Heartbeat.SCREEN_ON_MS)
        assertEquals(90_000L, Heartbeat.SCREEN_OFF_MS)
        assertEquals(240_000, Heartbeat.IDLE_TIMEOUT_MS)
        assertEquals(Heartbeat.SCREEN_ON_MS, Heartbeat.intervalMs(true))
        assertEquals(Heartbeat.SCREEN_OFF_MS, Heartbeat.intervalMs(false))
        assertEquals(240_000, Handshake.IDLE_TIMEOUT_MS)
        // The ping must be several times more frequent than the drop timeout.
        assert(Heartbeat.SCREEN_OFF_MS * 2 < Heartbeat.IDLE_TIMEOUT_MS)
    }
}

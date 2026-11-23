package com.mydroid.protocol

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class VectorsTest {
    private val v: JsonObject = run {
        val f = listOf("../../protocol/test-vectors.json", "../protocol/test-vectors.json", "protocol/test-vectors.json")
            .map { File(it) }.first { it.exists() }
        Json.parseToJsonElement(f.readText()).jsonObject
    }
    private fun s(k: String) = v[k]!!.jsonPrimitive.content
    private val ltk = Hex.decode(s("ltk"))
    private val nc = Hex.decode(s("nonceClient"))
    private val ns = Hex.decode(s("nonceServer"))

    @Test fun pairingSecretEncodingMatches() {
        assertEquals(s("pairingSecret"), Hex.encode(B64.decodeUrl(s("pairingSecretB64url"))))
    }

    @Test fun ltk() {
        assertEquals(s("ltk"), Hex.encode(Keys.ltkFromSecret(Hex.decode(s("pairingSecret")))))
    }

    @Test fun sessionKeysAndConfirm() {
        val k = Keys.session(ltk, nc, ns)
        assertEquals(s("c2sKey"), Hex.encode(k.c2s))
        assertEquals(s("s2cKey"), Hex.encode(k.s2c))
        assertEquals(s("confirmCode"), k.confirmCode)
        assertEquals("181 734", Keys.displayCode(k.confirmCode))
        val raw = Hkdf.derive(ltk, nc + ns, "mydroid v1 confirm", 4)
        assertEquals(s("confirmBytes"), Hex.encode(raw))
    }

    @Test fun hkdfRfc5869Case1() {
        val ikm = ByteArray(22) { 0x0b }
        val salt = Hex.decode("000102030405060708090a0b0c")
        val info = Hex.decode("f0f1f2f3f4f5f6f7f8f9")
        val okm = Hkdf.expand(Hkdf.extract(salt, ikm), info, 42)
        assertEquals("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865", Hex.encode(okm))
    }

    @Test fun framesSealAndOpenAndMatchVectors() {
        val keys = Keys.session(ltk, nc, ns)
        for (f in v["frames"]!!.jsonArray.map { it.jsonObject }) {
            val c2s = f["dir"]!!.jsonPrimitive.content == "c2s"
            val counter = f["counter"]!!.jsonPrimitive.long
            val cipher = FrameCipher(if (c2s) keys.c2s else keys.s2c)
            val frame = Hex.decode(f["frame"]!!.jsonPrimitive.content)
            val plain = Hex.decode(f["plaintext"]!!.jsonPrimitive.content)
            assertArrayEquals("open ${f["dir"]}#$counter", plain, cipher.open(counter, frame))
            assertArrayEquals("seal ${f["dir"]}#$counter", frame, cipher.seal(counter, plain))
            // plaintext must be decodable as a message
            assertTrue(Codec.decode(plain).type.isNotEmpty())
        }
    }

    @Test fun codecReproducesVectorPlaintexts() {
        val frames = v["frames"]!!.jsonArray.map { it.jsonObject }
        val auth = Message.of("auth") { put("name", "Pixel 9"); put("model", "Pixel 9") }
        assertEquals(frames[0]["plaintext"]!!.jsonPrimitive.content, Hex.encode(Codec.encode(auth)))
        val chunk = Message.of("xfer.chunk", byteArrayOf(1, 2, 3, 4, 5)) { put("xid", "photo:1:100"); put("offset", 0) }
        assertEquals(frames[1]["plaintext"]!!.jsonPrimitive.content, Hex.encode(Codec.encode(chunk)))
        val welcome = Message.of("welcome") { put("name", "MacBook") }
        assertEquals(frames[2]["plaintext"]!!.jsonPrimitive.content, Hex.encode(Codec.encode(welcome)))
    }

    @Test fun counterMismatchAndTamperRejected() {
        val keys = Keys.session(ltk, nc, ns)
        val c = FrameCipher(keys.c2s)
        val frame = c.seal(0, byteArrayOf(1, 2, 3))
        assertThrows(ProtocolException::class.java) { c.open(1, frame) }
        frame[frame.size - 1] = (frame[frame.size - 1].toInt() xor 1).toByte()
        assertThrows(ProtocolException::class.java) { c.open(0, frame) }
    }
}

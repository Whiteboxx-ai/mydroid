package com.mydroid.simulator

import com.mydroid.protocol.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.PrintStream
import java.net.ServerSocket
import java.net.Socket
import java.nio.file.Files
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.atomic.AtomicReference

/** A minimal in-test Mac: speaks the server side of PROTOCOL.md using the same :protocol primitives. */
private class FakeServer(val dir: File) : AutoCloseable {
    val macId = UUID.randomUUID().toString()
    val secret = ByteArray(32).also { SecureRandom().nextBytes(it) }
    val ltk = Keys.ltkFromSecret(secret)
    val ss = ServerSocket(0, 5, java.net.InetAddress.getLoopbackAddress())
    val ledger = MemoryLedger()
    var pairedPhone: String? = null
    val serverError = AtomicReference<Throwable?>(null)
    val acceptOffsets = java.util.concurrent.CopyOnWriteArrayList<Pair<String, Long>>()
    @Volatile var fileDone = false
    @Volatile var photo1Offers = 0

    val store = object : IncomingStore {
        override fun partFile(offer: Offer) = File(dir, "parts/" + offer.xid.replace(':', '_') + ".part")
        override fun complete(offer: Offer, part: File) {
            File(dir, "Pictures").mkdirs(); part.copyTo(File(dir, "Pictures/${offer.name}"), overwrite = true)
        }
    }

    val url get() = "mydroid://pair?v=1&mac=$macId&n=Test%20Mac&s=${java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(secret)}&a=127.0.0.1:${ss.localPort}"

    init {
        Thread {
            try {
                while (true) {
                    val s = ss.accept()
                    Thread { try { serve(s) } catch (e: IOException) { /* client dropped */ } catch (e: Throwable) { serverError.set(e) } }.apply { isDaemon = true }.start()
                }
            } catch (_: IOException) { }
        }.apply { isDaemon = true }.start()
    }

    private fun serve(s: Socket) {
        s.soTimeout = 20_000
        val ins = s.getInputStream().buffered(); val outs = s.getOutputStream().buffered()
        val hello = Json.parseToJsonElement(String(Codec.readFrame(ins))).jsonObject
        val phone = hello["phone"]!!.jsonPrimitive.content
        val pairing = hello["pairing"]!!.jsonPrimitive.boolean
        if (!pairing && phone != pairedPhone) { s.close(); return }
        val nonceC = B64.decodeStd(hello["nonce"]!!.jsonPrimitive.content)
        val nonceS = ByteArray(16).also { SecureRandom().nextBytes(it) }
        Codec.writeFrame(outs, buildJsonObject { put("t", "hello"); put("v", 1); put("mac", macId); put("nonce", B64.std(nonceS)) }.toString().toByteArray())
        val keys = Keys.session(ltk, nonceC, nonceS)
        val rc = FrameCipher(keys.c2s); val sc = FrameCipher(keys.s2c)
        var rn = 0L; var sn = 0L
        fun send(m: Message) = synchronized(s) {
            if (m.type == "xfer.accept") acceptOffsets += m.str("xid")!! to m.long("offset")!!
            Codec.writeFrame(outs, sc.seal(sn++, Codec.encode(m))) }
        fun recv(): Message = Codec.decode(rc.open(rn++, Codec.readFrame(ins)))
        val engine = TransferEngine(::send, ledger, store)
        while (true) {
            val m = try { recv() } catch (e: IOException) { engine.connectionLost(); throw e }
            if (engine.handle(m)) {
                if (m.type == "xfer.skip") { /* nothing */ }
                if (m.type == "xfer.offer") {
                    if (m.str("xid") == "photo:1:100" && ledger.has("photo:1:100")) {
                        Thread {
                            val f = File(dir, "hello.txt").also { it.writeText("hello from mac\n") }
                            val r = engine.sendFile(Offer("file:${UUID.randomUUID()}", "file", "hello.txt", f.length(), "text/plain"), FileFileSource(f))
                            fileDone = r == SendResult.DONE
                        }.start()
                    }
                }
                continue
            }
            when (m.type) {
                "auth" -> {
                    send(Message.of("welcome") { put("name", "Test Mac") })
                    if (pairing) {
                        pairedPhone = phone
                        send(Message.of("pair.confirmed"))
                    }
                }
                "notif.snapshot" -> send(Message.of("settings") { for (f in listOf("notifications", "photos", "calls", "clipboard")) put(f, true) })
                "notif.posted" -> send(Message.of("notif.reply") { put("key", "k1"); put("text", "On my way") })
                "clip.set" -> {
                    assertEquals("hello from phone", m.str("text"))
                    send(Message.of("clip.set") { put("text", "hello from mac") })
                    send(Message.of("ping"))
                }
                "bye" -> { s.close(); return }
            }
        }
    }

    override fun close() = ss.close()
}

class SmokeScenarioTest {
    @Test fun fullScenarioAgainstFakeServer() {
        val d = Files.createTempDirectory("smoke").toFile()
        val srv = FakeServer(File(d, "server"))
        val p1 = File(d, "p1.bin").apply { writeBytes(ByteArray(1_500_000).also(SecureRandom()::nextBytes)) }
        val p2 = File(d, "p2.bin").apply { writeBytes(ByteArray(1_500_000).also(SecureRandom()::nextBytes)) }
        val buf = ByteArrayOutputStream()
        srv.use { Smoke.run(srv.url, File(d, "state"), p1, p2, PrintStream(buf, true)) }
        val log = buf.toString()
        println(log)
        assertNull(srv.serverError.get())
        for (n in 1..10) assertTrue("STEP $n ok missing in:\n$log", log.contains("STEP $n ok"))
        assertTrue(Regex("CONFIRM \\d{6}").containsMatchIn(log))
        // resume proof: second offer of photo:2:100 was accepted at exactly one chunk
        assertTrue(srv.acceptOffsets.toString(), srv.acceptOffsets.contains("photo:2:100" to 262144L))
        assertEquals(Hashing.sha256Hex(p1), Hashing.sha256Hex(File(d, "server/Pictures/p1.bin")))
        assertEquals(Hashing.sha256Hex(p2), Hashing.sha256Hex(File(d, "server/Pictures/p2.bin")))
        Thread.sleep(300)
        assertTrue("server file send not completed", srv.fileDone)
    }

    @Test fun failsCleanlyWhenNothingListens() {
        val d = Files.createTempDirectory("smoke").toFile()
        val p = File(d, "p.bin").apply { writeBytes(ByteArray(10)) }
        try {
            Smoke.run("mydroid://pair?v=1&mac=x&n=Mac&s=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&a=127.0.0.1:1", File(d, "s"), p, p)
            fail()
        } catch (e: SmokeFailure) {
            assertTrue(e.message!!, e.message!!.startsWith("could not connect"))
        }
    }
}

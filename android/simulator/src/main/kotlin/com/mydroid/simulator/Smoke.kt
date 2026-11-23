package com.mydroid.simulator

import com.mydroid.protocol.*
import kotlinx.serialization.json.*
import java.io.File
import java.io.IOException
import java.io.PrintStream
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

class SmokeFailure(msg: String) : Exception(msg)

/** Persistent client identity, mirrors what the Android app stores. */
class SimState(private val dir: File) {
    private val file = File(dir, "state.json")
    var phoneId: String = ""; var macId: String = ""; var macName: String = ""; var ltkHex: String = ""
    var addresses: List<String> = emptyList()

    init {
        dir.mkdirs()
        if (file.exists()) {
            val o = Json.parseToJsonElement(file.readText()).jsonObject
            phoneId = o["phoneId"]!!.jsonPrimitive.content; macId = o["macId"]!!.jsonPrimitive.content
            macName = o["macName"]!!.jsonPrimitive.content; ltkHex = o["ltk"]!!.jsonPrimitive.content
            addresses = o["addresses"]!!.jsonArray.map { it.jsonPrimitive.content }
        }
    }

    fun ensurePhoneId(): String {
        if (phoneId.isEmpty()) phoneId = UUID.randomUUID().toString()
        return phoneId
    }

    fun save() {
        file.writeText(
            buildJsonObject {
                put("phoneId", phoneId); put("macId", macId); put("macName", macName); put("ltk", ltkHex)
                put("addresses", JsonArray(addresses.map { JsonPrimitive(it) }))
            }.toString(),
        )
    }
}

class FileLedger(private val file: File) : Ledger {
    private val set = HashSet<String>().also { if (file.exists()) it += file.readLines() }
    @Synchronized override fun has(xid: String) = xid in set
    @Synchronized override fun record(xid: String) {
        if (set.add(xid)) file.appendText(xid + "\n")
    }
}

class SimIncoming(private val dir: File) : IncomingStore {
    val received = LinkedBlockingQueue<Pair<Offer, ByteArray>>()
    override fun partFile(offer: Offer) = File(dir, "parts/" + offer.xid.replace(Regex("[^A-Za-z0-9._-]"), "_") + ".part")
    override fun complete(offer: Offer, part: File) {
        val dest = File(dir, "incoming/${offer.name}")
        dest.parentFile.mkdirs()
        part.copyTo(dest, overwrite = true)
    }
    override fun delivered(offer: Offer) {
        received.put(offer to File(dir, "incoming/${offer.name}").readBytes())
    }
}

/** One live connection in the simulator, using exactly the :protocol client paths the app uses. */
class SimConnection(
    val session: ClientSession,
    val transfers: TransferEngine,
    private val inbox: LinkedBlockingQueue<Message>,
    private val ready: CountDownLatch,
    private val closed: CountDownLatch,
) {
    fun send(m: Message) = session.send(m)

    fun expect(type: String, timeoutMs: Long = 10_000, pred: (Message) -> Boolean = { true }): Message {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (true) {
            val left = deadline - System.currentTimeMillis()
            if (left <= 0) throw SmokeFailure("timed out waiting for $type")
            val m = inbox.poll(left, TimeUnit.MILLISECONDS) ?: throw SmokeFailure("timed out waiting for $type")
            if (m.type == type && pred(m)) return m
            if (closed.count == 0L && inbox.isEmpty()) throw SmokeFailure("connection closed while waiting for $type")
        }
    }

    fun awaitReady(timeoutMs: Long = 10_000) {
        if (!ready.await(timeoutMs, TimeUnit.MILLISECONDS)) throw SmokeFailure("session did not become ready")
    }

    fun close() = session.close()
}

class SmokeClient(private val stateDir: File, private val out: PrintStream) {
    val state = SimState(stateDir)
    private val ledger = FileLedger(File(stateDir, "ledger.txt"))
    val incoming = SimIncoming(stateDir)

    @Volatile var confirmCode: String? = null
    private val codeLatch = CountDownLatch(1)
    @Volatile var rejected = false

    fun connect(target: HostPort, macId: String, ltk: ByteArray, pairing: Boolean, onPaired: (() -> Unit)? = null): SimConnection {
        val racer = CandidateRacer { hp -> Handshake.connect(hp, state.ensurePhoneId(), macId, pairing, ltk) }
        racer.add(target)
        val channel = racer.await(8_000) ?: throw SmokeFailure("could not connect to $target: ${racer.lastErrors.joinToString()}")
        val inbox = LinkedBlockingQueue<Message>()
        val ready = CountDownLatch(1)
        val closed = CountDownLatch(1)
        lateinit var transfers: TransferEngine
        val listener = object : SessionListener {
            override fun onConfirmCode(code: String) {
                confirmCode = code; out.println("CONFIRM $code"); out.flush(); codeLatch.countDown()
            }
            override fun onReady(pairing: Boolean, macName: String) {
                if (pairing) {
                    state.macName = macName; onPaired?.invoke()
                }
                ready.countDown()
            }
            override fun onRejected() { rejected = true }
            override fun onMessage(m: Message) {
                if (!transfers.handle(m)) inbox.put(m)
            }
            override fun onClosed(reason: String?) {
                transfers.connectionLost(); closed.countDown()
            }
        }
        val session = ClientSession(channel, DeviceIdentity("Pixel 9", "Pixel 9", 35), pairing, listener)
        transfers = TransferEngine({ session.send(it) }, ledger, incoming)
        Thread({ session.run() }, "sim-session").apply { isDaemon = true }.start()
        return SimConnection(session, transfers, inbox, ready, closed)
    }
}

object Smoke {
    fun run(url: String, stateDir: File, photo: File, photo2: File, out: PrintStream = System.out) {
        fun step(n: Int) { out.println("STEP $n ok"); out.flush() }
        val pu = PairingUrl.parse(url) ?: throw SmokeFailure("bad pairing url")
        val first = pu.addresses.firstOrNull() ?: throw SmokeFailure("pairing url has no addresses")
        for (f in listOf(photo, photo2)) if (!f.isFile) throw SmokeFailure("missing photo file ${f.path}")
        stateDir.mkdirs()
        val client = SmokeClient(stateDir, out)
        val st = client.state
        step(1)

        // 2. pair
        st.ensurePhoneId()
        val ltk = Keys.ltkFromSecret(pu.secret)
        val c1 = client.connect(first, pu.macId, ltk, pairing = true) {
            st.macId = pu.macId; st.ltkHex = Hex.encode(ltk); st.addresses = pu.addresses.map { it.toString() }; st.save()
        }
        c1.awaitReady(15_000)
        if (client.confirmCode == null) throw SmokeFailure("no confirm code")
        c1.session.sayGoodbye()
        step(2)

        // 3. reconnect with stored LTK
        val stored = SimState(stateDir)
        val storedLtk = Hex.decode(stored.ltkHex)
        val addr = HostPort.parse(stored.addresses.first())!!
        val client2 = SmokeClient(stateDir, out)
        var c = client2.connect(addr, stored.macId, storedLtk, pairing = false)
        c.awaitReady()
        c.send(Message.of("device.status") { put("battery", 78); put("charging", false); put("network", "wifi"); put("name", "Pixel 9"); put("model", "Pixel 9") })
        c.send(Message.of("feature.status") {
            for (f in listOf("notifications", "photos", "calls", "clipboard")) put(f, "on")
            put("backgroundRestricted", false)
        })
        c.send(Message.of("notif.snapshot") { put("items", JsonArray(emptyList())) })
        val settings = c.expect("settings")
        for (f in listOf("notifications", "photos", "calls", "clipboard")) {
            if (settings.bool(f) != true) throw SmokeFailure("settings.$f is not true")
        }
        step(3)

        // 4. notification + reply
        c.send(
            Message.of("notif.posted") {
                put("key", "k1"); put("pkg", "com.example.messages"); put("app", "Messages")
                put("title", "Maya Tan"); put("text", "Are we still on for coffee?")
                put("when", System.currentTimeMillis()); put("canReply", true)
                put("actions", JsonArray(emptyList()))
            },
        )
        val reply = c.expect("notif.reply")
        if (reply.str("key") != "k1") throw SmokeFailure("reply key ${reply.str("key")}")
        if (reply.str("text") != "On my way") throw SmokeFailure("reply text '${reply.str("text")}'")
        c.send(Message.of("notif.result") { put("key", "k1"); put("ok", true) })
        c.send(Message.of("notif.removed") { put("key", "k1") })
        step(4)

        // 5. photo 1
        fun offerFor(f: File, id: Int) = Offer("photo:$id:100", "photo", f.name, f.length(), "image/jpeg", System.currentTimeMillis())
        val r1 = c.transfers.sendFile(offerFor(photo, 1), FileFileSource(photo))
        if (r1 != SendResult.DONE) throw SmokeFailure("photo:1:100 ended $r1")
        step(5)

        // 6. photo 2: one chunk, drop, resume
        val o2 = offerFor(photo2, 2)
        if (photo2.length() <= CHUNK_SIZE) throw SmokeFailure("photo2 must be larger than one chunk")
        try {
            c.transfers.sendFile(o2, FileFileSource(photo2), ChunkHook { i, _ ->
                if (i == 1) {
                    c.session.channel.close()
                    throw IOException("simulated drop")
                }
            })
            throw SmokeFailure("photo2 unexpectedly completed before the drop")
        } catch (_: IOException) {
        }
        Thread.sleep(300)
        c = client2.connect(addr, stored.macId, storedLtk, pairing = false)
        c.awaitReady()
        var firstOffset = -1L
        val r2 = c.transfers.sendFile(o2, FileFileSource(photo2), ChunkHook { i, off -> if (i == 0) firstOffset = off })
        if (firstOffset != CHUNK_SIZE.toLong()) throw SmokeFailure("resume offset was $firstOffset, expected $CHUNK_SIZE")
        if (r2 != SendResult.DONE) throw SmokeFailure("photo:2:100 ended $r2")
        step(6)

        // 7. duplicate offer
        val r3 = c.transfers.sendFile(offerFor(photo, 1), FileFileSource(photo))
        if (r3 != SendResult.SKIPPED) throw SmokeFailure("duplicate photo:1:100 ended $r3, expected skip")
        step(7)

        // 8. file from Mac
        val got = client2.incoming.received.poll(15, TimeUnit.SECONDS) ?: throw SmokeFailure("no file received from Mac")
        if (got.first.name != "hello.txt" || !got.first.xid.startsWith("file:")) throw SmokeFailure("unexpected file offer ${got.first}")
        if (String(got.second) != "hello from mac\n") throw SmokeFailure("file content '${String(got.second)}'")
        step(8)

        // 9. clipboard
        c.send(Message.of("clip.set") { put("text", "hello from phone") })
        val clip = c.expect("clip.set")
        if (clip.str("text") != "hello from mac") throw SmokeFailure("clip text '${clip.str("text")}'")
        step(9)

        // 10. ping/pong then bye (pong is automatic in ClientSession)
        c.expect("ping")
        c.session.sayGoodbye()
        step(10)
    }
}

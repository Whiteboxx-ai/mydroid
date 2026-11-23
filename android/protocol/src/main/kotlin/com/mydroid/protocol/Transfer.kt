package com.mydroid.protocol

import kotlinx.serialization.json.put
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

data class Offer(
    val xid: String,
    val kind: String,
    val name: String,
    val size: Long,
    val mime: String,
    val taken: Long? = null,
) {
    fun toMessage(): Message = Message.of("xfer.offer") {
        put("xid", xid); put("kind", kind); put("name", name); put("size", size); put("mime", mime)
        if (taken != null) put("taken", taken)
    }

    companion object {
        fun from(m: Message): Offer? {
            return Offer(
                m.str("xid") ?: return null,
                m.str("kind") ?: "file",
                m.str("name") ?: return null,
                m.long("size") ?: return null,
                m.str("mime") ?: "application/octet-stream",
                m.long("taken"),
            )
        }
    }
}

/** Where outgoing bytes come from (MediaStore, a file, ...). */
interface FileSource {
    val size: Long

    /** Open positioned at [offset]. */
    fun open(offset: Long): InputStream
}

class FileFileSource(private val file: File) : FileSource {
    override val size: Long get() = file.length()
    override fun open(offset: Long): InputStream =
        java.io.RandomAccessFile(file, "r").let { raf ->
            raf.seek(offset)
            object : InputStream() {
                override fun read(): Int = raf.read()
                override fun read(b: ByteArray, off: Int, len: Int): Int = raf.read(b, off, len)
                override fun close() = raf.close()
            }
        }
}

/** Dedupe ledger of receiver-side completed xids. */
interface Ledger {
    fun has(xid: String): Boolean
    fun record(xid: String)
}

class MemoryLedger : Ledger {
    private val set = ConcurrentHashMap.newKeySet<String>()
    override fun has(xid: String) = xid in set
    override fun record(xid: String) {
        set += xid
    }
}

/** Receiver storage. Partial files are kept so a dropped transfer resumes at its size. */
interface IncomingStore {
    /** Stable `.part` file for this offer (stable across reconnects: derive from xid). */
    fun partFile(offer: Offer): File

    /** Move/copy the verified [part] into its final place. Throw on failure. */
    fun complete(offer: Offer, part: File)
    /** Called after `xfer.done ok` has been sent, so anything the caller sends next is ordered after the ack. */
    fun delivered(offer: Offer) {}
}

enum class SendResult { DONE, SKIPPED, FAILED, CANCELLED }

fun interface ChunkHook {
    /** Called before every chunk is sent; may throw to simulate a dropped link. [index] is 0-based within this send. */
    fun beforeChunk(index: Int, offset: Long)
}

object Hashing {
    fun sha256Hex(f: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        f.inputStream().use { ins ->
            val buf = ByteArray(64 * 1024)
            while (true) {
                val n = ins.read(buf)
                if (n < 0) break
                md.update(buf, 0, n)
            }
        }
        return Hex.encode(md.digest())
    }
}

/**
 * Symmetric transfer engine: [sendFile] is the sender role, [handle] feeds incoming `xfer.*` frames
 * (receiver role for offer/chunk/end, sender role for accept/skip/done/cancel).
 */
class TransferEngine(
    private val send: (Message) -> Unit,
    private val ledger: Ledger,
    private val store: IncomingStore,
    private val log: (String) -> Unit = {},
) {
    private class Receiving(val offer: Offer, val part: File, var out: FileOutputStream, var expected: Long)

    private val receiving = ConcurrentHashMap<String, Receiving>()
    private val waiters = ConcurrentHashMap<String, LinkedBlockingQueue<Message>>()
    private val abort = Message.of("xfer.abort")

    /** True if the message was an `xfer.*` message and has been consumed. */
    fun handle(m: Message): Boolean {
        if (!m.type.startsWith("xfer.")) return false
        val xid = m.str("xid") ?: return true
        when (m.type) {
            "xfer.accept", "xfer.skip", "xfer.done" -> waiters[xid]?.put(m)
            "xfer.cancel" -> {
                waiters[xid]?.put(m)
                receiving.remove(xid)?.let { it.out.close(); it.part.delete() }
            }
            "xfer.offer" -> onOffer(m)
            "xfer.chunk" -> onChunk(xid, m)
            "xfer.end" -> onEnd(xid, m)
        }
        return true
    }

    /** Connection dropped: wake senders and close partial files (keeping them for resume). */
    fun connectionLost() {
        waiters.values.forEach { it.put(abort) }
        receiving.values.forEach { runCatching { it.out.close() } }
        receiving.clear()
    }

    private fun onOffer(m: Message) {
        val offer = Offer.from(m) ?: return
        if (ledger.has(offer.xid)) {
            send(Message.of("xfer.skip") { put("xid", offer.xid) })
            return
        }
        receiving.remove(offer.xid)?.out?.close()
        val part = store.partFile(offer)
        var have = if (part.exists()) part.length() else 0L
        if (have > offer.size) {
            part.delete(); have = 0
        }
        part.parentFile?.mkdirs()
        val out = FileOutputStream(part, true)
        receiving[offer.xid] = Receiving(offer, part, out, have)
        send(Message.of("xfer.accept") { put("xid", offer.xid); put("offset", have) })
    }

    private fun fail(xid: String, error: String) {
        receiving.remove(xid)?.let { runCatching { it.out.close() }; it.part.delete() }
        send(Message.of("xfer.done") { put("xid", xid); put("ok", false); put("error", error) })
    }

    private fun onChunk(xid: String, m: Message) {
        val r = receiving[xid] ?: return fail(xid, "no transfer in progress")
        val off = m.long("offset") ?: return fail(xid, "chunk without offset")
        if (off != r.expected) return fail(xid, "unexpected offset $off, wanted ${r.expected}")
        r.out.write(m.payload)
        r.expected += m.payload.size
    }

    private fun onEnd(xid: String, m: Message) {
        val r = receiving.remove(xid) ?: return fail(xid, "no transfer in progress")
        r.out.close()
        val want = m.str("sha256")?.lowercase()
        if (r.part.length() != r.offer.size) {
            r.part.delete(); return send(Message.of("xfer.done") { put("xid", xid); put("ok", false); put("error", "size mismatch") })
        }
        if (want == null || Hashing.sha256Hex(r.part) != want) {
            r.part.delete(); return send(Message.of("xfer.done") { put("xid", xid); put("ok", false); put("error", "sha256 mismatch") })
        }
        try {
            store.complete(r.offer, r.part)
        } catch (e: Exception) {
            return send(Message.of("xfer.done") { put("xid", xid); put("ok", false); put("error", e.message ?: "save failed") })
        }
        ledger.record(xid)
        r.part.delete()
        send(Message.of("xfer.done") { put("xid", xid); put("ok", true) })
        store.delivered(r.offer)
    }

    /**
     * Sender role. Blocks until `xfer.done`/`xfer.skip`. Throws IOException if the link drops
     * (the caller keeps the item queued and retries after reconnect).
     */
    fun sendFile(offer: Offer, source: FileSource, hook: ChunkHook? = null, timeoutMs: Long = 30_000): SendResult {
        val q = LinkedBlockingQueue<Message>()
        waiters[offer.xid] = q
        try {
            send(offer.toMessage())
            val reply = await(q, timeoutMs)
            when (reply.type) {
                "xfer.skip" -> return SendResult.SKIPPED
                "xfer.cancel" -> return SendResult.CANCELLED
                "xfer.accept" -> {}
                else -> throw java.io.IOException("unexpected ${reply.type}")
            }
            val offset = (reply.long("offset") ?: 0L).coerceIn(0L, source.size)
            val md = MessageDigest.getInstance("SHA-256")
            // The hash covers the whole file, so re-read the part the receiver already has.
            source.open(0).use { ins ->
                var remaining = offset
                val buf = ByteArray(64 * 1024)
                while (remaining > 0) {
                    val n = ins.read(buf, 0, minOf(buf.size.toLong(), remaining).toInt())
                    if (n < 0) throw java.io.IOException("source shorter than expected")
                    md.update(buf, 0, n)
                    remaining -= n
                }
            }
            var pos = offset
            var index = 0
            source.open(offset).use { ins ->
                val buf = ByteArray(CHUNK_SIZE)
                while (pos < source.size) {
                    val want = minOf(CHUNK_SIZE.toLong(), source.size - pos).toInt()
                    var got = 0
                    while (got < want) {
                        val n = ins.read(buf, got, want - got)
                        if (n < 0) break
                        got += n
                    }
                    if (got <= 0) throw java.io.IOException("source ended early")
                    hook?.beforeChunk(index, pos)
                    val payload = if (got == buf.size) buf.copyOf() else buf.copyOf(got)
                    md.update(payload)
                    send(Message.of("xfer.chunk", payload) { put("xid", offer.xid); put("offset", pos) })
                    pos += got
                    index++
                    // Drain an early cancel without blocking.
                    q.peek()?.let { if (it.type == "xfer.cancel") return SendResult.CANCELLED }
                }
            }
            send(Message.of("xfer.end") { put("xid", offer.xid); put("sha256", Hex.encode(md.digest())) })
            while (true) {
                val done = await(q, timeoutMs)
                when (done.type) {
                    "xfer.done" -> return if (done.bool("ok") == true) SendResult.DONE else {
                        log("xfer ${offer.xid} failed: ${done.str("error")}")
                        SendResult.FAILED
                    }
                    "xfer.cancel" -> return SendResult.CANCELLED
                }
            }
        } finally {
            waiters.remove(offer.xid)
        }
    }

    private fun await(q: LinkedBlockingQueue<Message>, timeoutMs: Long): Message {
        val m = q.poll(timeoutMs, TimeUnit.MILLISECONDS) ?: throw java.io.IOException("transfer timed out")
        if (m.type == "xfer.abort") throw java.io.IOException("connection lost")
        return m
    }
}

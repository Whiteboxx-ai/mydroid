package com.mydroid.protocol

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.Random
import java.util.concurrent.LinkedBlockingQueue

class TransferTest {
    private class Store(val dir: File) : IncomingStore {
        val done = mutableListOf<String>()
        override fun partFile(offer: Offer) = File(dir, offer.xid.replace(':', '_') + ".part")
        override fun complete(offer: Offer, part: File) {
            part.copyTo(File(dir, offer.name), overwrite = true); done += offer.name
        }
    }

    /** Wires a sender engine and receiver engine back-to-back through queues. */
    private class Pair2(val dir: File, val ledger: Ledger = MemoryLedger()) {
        val store = Store(dir)
        lateinit var a: TransferEngine
        lateinit var b: TransferEngine
        @Volatile var open = true
        val offsets = java.util.concurrent.CopyOnWriteArrayList<Long>()
        val toB = LinkedBlockingQueue<Message>()
        val toA = LinkedBlockingQueue<Message>()
        init {
            a = TransferEngine({ if (!open) throw IOException("closed"); if (it.type == "xfer.chunk") offsets += it.long("offset")!!; toB.put(it) }, MemoryLedger(), Store(File(dir, "a")))
            b = TransferEngine({ if (!open) throw IOException("closed"); toA.put(it) }, ledger, store)
            pump(toB) { b.handle(it) }; pump(toA) { a.handle(it) }
        }
        private fun pump(q: LinkedBlockingQueue<Message>, f: (Message) -> Unit) =
            Thread { while (true) f(q.take()) }.apply { isDaemon = true }.start()
    }

    private fun tmp() = Files.createTempDirectory("xfer").toFile()
    private fun src(dir: File, size: Int): File = File(dir, "src.bin").also { Random(1).let { r -> it.writeBytes(ByteArray(size).also(r::nextBytes)) } }

    @Test fun fullTransferThenDedupeSkip() {
        val d = tmp(); val p = Pair2(d); val f = src(d, 700_000)
        val offer = Offer("photo:1:100", "photo", "a.jpg", f.length(), "image/jpeg", 5)
        assertEquals(SendResult.DONE, p.a.sendFile(offer, FileFileSource(f)))
        assertEquals(Hashing.sha256Hex(f), Hashing.sha256Hex(File(d, "a.jpg")))
        assertEquals(SendResult.SKIPPED, p.a.sendFile(offer, FileFileSource(f)))
    }

    @Test fun resumeFromPartAfterDrop() {
        val d = tmp(); val p = Pair2(d); val f = src(d, 700_000)
        val offer = Offer("photo:2:100", "photo", "b.jpg", f.length(), "image/jpeg")
        try {
            p.a.sendFile(offer, FileFileSource(f), ChunkHook { i, _ -> if (i == 1) throw IOException("drop") })
            fail()
        } catch (e: IOException) { }
        Thread.sleep(200)
        assertEquals(CHUNK_SIZE.toLong(), p.store.partFile(offer).length())
        p.b.connectionLost()
        // fresh "connection": the receiver must accept at the part's size
        p.offsets.clear()
        assertEquals(SendResult.DONE, p.a.sendFile(offer, FileFileSource(f)))
        assertEquals(CHUNK_SIZE.toLong(), p.offsets.first())
        assertEquals(Hashing.sha256Hex(f), Hashing.sha256Hex(File(d, "b.jpg")))
    }

    @Test fun badHashIsFailed() {
        val d = tmp(); val p = Pair2(d); val f = src(d, 1000)
        val bad = FileSource::class.java.let {
            object : FileSource {
                override val size = 1000L
                override fun open(offset: Long) = f.inputStream().also { s -> s.skip(offset) }
            }
        }
        // Receiver expects 1001 bytes -> size mismatch
        val offer = Offer("file:x", "file", "x.bin", 1001, "application/octet-stream")
        try {
            p.a.sendFile(offer, object : FileSource { override val size = 1001L; override fun open(offset: Long) = bad.open(offset) })
            fail()
        } catch (e: IOException) { /* source ended early */ }
    }
}

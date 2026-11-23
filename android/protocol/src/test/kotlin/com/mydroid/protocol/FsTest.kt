package com.mydroid.protocol

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.Random
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutionException
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

private fun rt(m: Message): Message = Codec.decode(Codec.encode(m))
private fun tmpDir(): File = Files.createTempDirectory("fs").toFile()

private fun Message.assertField(k: String, v: String) = assertEquals(v, str(k))

class FsWireTest {
    @Test fun requestsRoundTrip() {
        rt(FsWire.roots("r1")).let { assertEquals("fs.roots", it.type); it.assertField("req", "r1") }
        rt(FsWire.list("r2", "docs", "a/b")).let { assertEquals("fs.list", it.type); it.assertField("root", "docs"); it.assertField("path", "a/b") }
        rt(FsWire.list("r2", "docs", "")).assertField("path", "")
        rt(FsWire.thumb("r3", "d", "x.jpg")).let { assertEquals("fs.thumb", it.type); it.assertField("path", "x.jpg") }
        rt(FsWire.get("r4", "d", "x.pdf")).let { assertEquals("fs.get", it.type); it.assertField("req", "r4") }
        rt(FsWire.put("r5", "d", "up", "n é.txt", 42)).let {
            assertEquals("fs.put", it.type); it.assertField("name", "n é.txt"); it.assertField("path", "up"); assertEquals(42L, it.long("size"))
        }
        rt(FsWire.search("r6", "tax 2025")).let { assertEquals("fs.search", it.type); it.assertField("query", "tax 2025") }
        assertEquals("fs.recent", rt(FsWire.recent("r7")).type)
    }

    @Test fun xids() {
        assertEquals("fs:abc", FsWire.xidGet("abc")); assertEquals("fsput:abc", FsWire.xidPut("abc"))
        assertEquals("abc", FsWire.reqOfGetXid("fs:abc")); assertNull(FsWire.reqOfGetXid("fsput:abc")); assertNull(FsWire.reqOfGetXid("fs:"))
        assertNull(FsWire.reqOfGetXid("photo:1:2"))
        assertTrue(FsWire.isFsXid("fs:1")); assertTrue(FsWire.isFsXid("fsput:1")); assertFalse(FsWire.isFsXid("file:1"))
    }

    @Test fun parsesRoots() {
        val m = Message.of("fs.roots.result") {
            put("req", "r"); put("macName", "Gautam's MacBook")
            put("roots", buildJsonArray {
                add(buildJsonObject { put("id", "desktop"); put("name", "Desktop"); put("writable", false) })
                add(buildJsonObject { put("id", "dl"); put("name", "Downloads"); put("writable", true) })
                add(buildJsonObject { put("name", "no id") })
                add(JsonPrimitive("junk"))
            })
        }
        val r = FsWire.parseRoots(rt(m))
        assertEquals("Gautam's MacBook", r.macName)
        assertEquals(listOf("desktop", "dl"), r.roots.map { it.id })
        assertTrue(r.anyWritable)
        assertEquals(FsRoots("", emptyList()), FsWire.parseRoots(Message.of("fs.roots.result") { put("roots", JsonArray(emptyList())) }))
    }

    @Test fun parsesListAndErrors() {
        val m = Message.of("fs.list.result") {
            put("req", "r")
            put("items", buildJsonArray {
                add(buildJsonObject { put("name", "Taxes"); put("dir", true); put("size", 0); put("mtime", 1_700_000_000_000L); put("mime", "inode/directory") })
                add(buildJsonObject { put("name", "a.pdf"); put("dir", false); put("size", 1234); put("mtime", 5L) }) // mime missing
                add(buildJsonObject { put("dir", false) }) // no name: dropped
            })
        }
        val o = FsWire.parseList(rt(m))
        assertTrue(o.ok)
        assertEquals(2, o.value!!.size)
        assertTrue(o.value!![0].dir); assertEquals(1234L, o.value!![1].size); assertEquals("application/octet-stream", o.value!![1].mime)
        val e = FsWire.parseList(Message.of("fs.list.result") { put("req", "r"); put("error", "denied") })
        assertFalse(e.ok); assertEquals("denied", e.error)
        assertTrue(FsWire.parseList(Message.of("fs.list.result") { put("req", "r") }).value!!.isEmpty())
    }

    @Test fun hitsAcceptFullPathOrParentFolder() {
        fun hit(path: String, name: String) = buildJsonObject { put("root", "docs"); put("path", path); put("name", name); put("dir", false); put("size", 1); put("mtime", 2); put("mime", "text/plain") }
        val m = Message.of("fs.search.result") { put("req", "r"); put("items", buildJsonArray { add(hit("Taxes/2025.pdf", "2025.pdf")); add(hit("Taxes", "2024.pdf")); add(hit("top.txt", "top.txt")); add(hit("", "x.txt")) }) }
        assertEquals(listOf("Taxes/2025.pdf", "Taxes/2024.pdf", "top.txt", "x.txt"), FsWire.parseHits(rt(m)).value!!.map { it.path })
        assertEquals("docs", FsWire.parseHits(m).value!![0].root)
        assertEquals("denied", FsWire.parseHits(Message.of("fs.search.result") { put("error", "denied") }).error)
    }
}

class FsDocIdTest {
    @Test fun roundTrips() {
        val root = FsDocId.parse("mac-1")!!
        assertTrue(root.isMacRoot); assertEquals("mac-1", root.encode())
        val share = FsDocId.parse("mac-1:docs")!!
        assertTrue(share.isShare); assertEquals("docs", share.share); assertEquals("", share.path)
        val f = FsDocId.parse("mac-1:docs/Taxes/2025 final.pdf")!!
        assertEquals("Taxes/2025 final.pdf", f.path); assertEquals("2025 final.pdf", f.name); assertEquals("Taxes", f.parentPath)
        assertEquals("mac-1:docs/Taxes/2025 final.pdf", f.encode())
        assertEquals(FsDocId.of("mac-1", "docs", "Taxes").child("2025 final.pdf"), f)
    }

    @Test fun shareIdsWithSlashesAreEscaped() {
        val id = FsDocId.of("m", "a/b%c", "x/y")
        assertEquals("m:a%2Fb%25c/x/y", id.encode())
        val back = FsDocId.parse(id.encode())!!
        assertEquals("a/b%c", back.share); assertEquals("x/y", back.path)
    }

    @Test fun rejectsTraversalAndGarbage() {
        assertNull(FsDocId.parse("m:docs/../etc")); assertNull(FsDocId.parse("m:docs//x")); assertNull(FsDocId.parse("m:docs/./x"))
        assertNull(FsDocId.parse("m:")); assertNull(FsDocId.parse(":docs")); assertNull(FsDocId.parse("")); assertNull(FsDocId.parse(null))
    }

    @Test fun parentsAndContainment() {
        val f = FsDocId.parse("m:docs/a/b.txt")!!
        assertEquals("m:docs/a", f.parent()!!.encode()); assertEquals("m:docs", f.parent()!!.parent()!!.encode()); assertEquals("m", f.parent()!!.parent()!!.parent()!!.encode())
        assertNull(FsDocId.parse("m")!!.parent())
        val mac = FsDocId.parse("m")!!; val docs = FsDocId.parse("m:docs")!!; val a = FsDocId.parse("m:docs/a")!!
        assertTrue(mac.contains(docs)); assertTrue(mac.contains(f)); assertTrue(docs.contains(a)); assertTrue(docs.contains(f)); assertTrue(a.contains(f))
        assertFalse(docs.contains(docs)); assertFalse(f.contains(a)); assertFalse(FsDocId.parse("m:docs/ab")!!.contains(FsDocId.parse("m:docs/abc/x")!!))
        assertFalse(docs.contains(FsDocId.parse("m:other/a")!!)); assertFalse(mac.contains(FsDocId.parse("n:docs")!!))
    }

    @Test fun namesAreSanitizedAndUnique() {
        assertEquals("a_b_c.txt", FsNames.sanitize("a/b\\c.txt")); assertEquals("_", FsNames.sanitize("..")); assertEquals("Untitled", FsNames.sanitize("  "))
        assertTrue(FsNames.sanitize("é".repeat(300)).toByteArray().size <= 255)
        assertEquals("x.txt", FsNames.unique("x.txt", listOf("y.txt")))
        assertEquals("x (1).txt", FsNames.unique("x.txt", listOf("X.TXT")))
        assertEquals("x (2).txt", FsNames.unique("x.txt", listOf("x.txt", "x (1).txt")))
        assertEquals("noext (1)", FsNames.unique("noext", listOf("noext")))
        assertEquals(".hidden (1)", FsNames.unique(".hidden", listOf(".hidden")))
    }
}

/** A scripted Mac: answers `fs.*` through [FsClient.onMessage] from another thread, like the request router does. */
private class FakeMacLink(val client: () -> FsClient) {
    val sent = CopyOnWriteArrayList<Message>()
    @Volatile var up = true
    @Volatile var script: (Message) -> Message? = { null }
    @Volatile var delayMs = 0L

    fun send(m: Message): Boolean {
        if (!up) return false
        sent += m
        val reply = script(m) ?: return true
        Thread { if (delayMs > 0) Thread.sleep(delayMs); client().onMessage(reply) }.apply { isDaemon = true }.start()
        return true
    }

    fun count(type: String) = sent.count { it.type == type }
}

private fun items(vararg names: String) = buildJsonArray {
    for (n in names) add(buildJsonObject { put("name", n); put("dir", n.endsWith("/")); put("size", 10); put("mtime", 100); put("mime", "text/plain") })
}

class FsClientTest {
    private fun setup(): Pair<FakeMacLink, FsClient> {
        lateinit var c: FsClient
        val link = FakeMacLink { c }
        c = FsClient(link::send, tmpDir(), newReq = AtomicInteger().let { n -> { "q${n.incrementAndGet()}" } })
        return link to c
    }

    @Test fun listResolvesByReq() {
        val (link, c) = setup()
        link.script = { if (it.type == "fs.list") Message.of("fs.list.result") { put("req", it.str("req")!!); put("items", items("a.txt", "Sub/")) } else null }
        val o = c.list("docs", "x").get(2, TimeUnit.SECONDS)
        assertTrue(o.ok); assertEquals(listOf("a.txt", "Sub"), o.value!!.map { it.name }.map { it.removeSuffix("/") })
        assertEquals("docs", link.sent.single().str("root"))
    }

    @Test fun errorsTimeoutsAndOffline() {
        val (link, c) = setup()
        link.script = { Message.of("fs.error") { put("req", it.str("req")!!); put("error", "denied") } }
        assertEquals("denied", c.list("d", "").get(2, TimeUnit.SECONDS).error)
        link.script = { null }
        assertEquals("timeout", c.list("d", "", timeoutMs = 80).get(2, TimeUnit.SECONDS).error)
        link.up = false
        assertEquals("offline", c.list("d", "").get(2, TimeUnit.SECONDS).error)
        assertEquals("offline", c.roots().get(2, TimeUnit.SECONDS).error)
    }

    @Test fun connectionLossFailsEverythingInFlight() {
        val (link, c) = setup()
        val l = c.list("d", ""); val s = c.search("x"); val g = c.get("d", "f", File(tmpDir(), "t"))
        c.connectionLost()
        assertEquals("offline", l.get(1, TimeUnit.SECONDS).error); assertEquals("offline", s.get(1, TimeUnit.SECONDS).error)
        try { g.done.get(1, TimeUnit.SECONDS); fail() } catch (e: ExecutionException) { assertEquals("offline", (e.cause as FsException).code) }
        assertEquals(3, link.sent.size)
    }

    @Test fun thumbNeedsPayload() {
        val (link, c) = setup()
        link.script = { Message.of("fs.thumb.result", byteArrayOf(1, 2, 3)) { put("req", it.str("req")!!); put("ok", true) } }
        assertArrayEquals(byteArrayOf(1, 2, 3), c.thumb("d", "a.jpg").get(2, TimeUnit.SECONDS).value)
        link.script = { Message.of("fs.thumb.result") { put("req", it.str("req")!!); put("ok", false) } }
        assertFalse(c.thumb("d", "a.jpg").get(2, TimeUnit.SECONDS).ok)
    }

    @Test fun putTicketCarriesTheXid() {
        val (link, c) = setup()
        link.script = { Message.of("fs.put.ready") { put("req", it.str("req")!!) } }
        val t = c.put("dl", "", "x.txt", 5).get(2, TimeUnit.SECONDS).value!!
        assertEquals("fsput:${link.sent.single().str("req")}", t.xid)
        link.script = { Message.of("fs.error") { put("req", it.str("req")!!); put("error", "denied") } }
        assertEquals("denied", c.put("dl", "", "x.txt", 5).get(2, TimeUnit.SECONDS).error)
    }

    @Test fun unknownAndLateRepliesAreIgnored() {
        val (_, c) = setup()
        assertTrue(c.onMessage(Message.of("fs.list.result") { put("req", "nobody") }))
        assertTrue(c.onMessage(Message.of("fs.error")))
        assertFalse(c.onMessage(Message.of("sms.send")))
    }
}

class FsBrowserTest {
    private class Rig(val connected: () -> Boolean = { true }) {
        lateinit var client: FsClient
        val link = FakeMacLink { client }
        val changed = LinkedBlockingQueue<FsBrowser.Key>()
        var clock = 1_000L
        lateinit var browser: FsBrowser
        init {
            client = FsClient(link::send, tmpDir())
            browser = FsBrowser(client, connected, { changed.put(it) }, now = { clock }, freshMs = 10_000, errorMs = 3_000)
        }
        fun listScript(names: () -> Array<String>) { link.script = { if (it.type == "fs.list") Message.of("fs.list.result") { put("req", it.str("req")!!); put("items", items(*names())) } else null } }
        fun await() = changed.poll(2, TimeUnit.SECONDS)
    }

    @Test fun firstCallIsLoadingThenChangeNotifiesAndNextCallHasRows() {
        val r = Rig(); r.listScript { arrayOf("a.txt", "b.txt") }
        val first = r.browser.children("docs", "")
        assertTrue(first.loading); assertTrue(first.items.isEmpty()); assertNull(first.error)
        assertEquals(FsBrowser.Key("ls", "docs", ""), r.await())
        val second = r.browser.children("docs", "")
        assertFalse(second.loading); assertEquals(2, second.items.size)
        assertEquals(1, r.link.count("fs.list"))
    }

    @Test fun oneRequestPerFolderAtATime() {
        val r = Rig(); r.link.delayMs = 150; r.listScript { arrayOf("a") }
        repeat(5) { assertTrue(r.browser.children("docs", "x").loading) }
        r.await()
        assertEquals(1, r.link.count("fs.list"))
    }

    @Test fun staleRowsAreServedWhileRefreshing() {
        val r = Rig(); var names = arrayOf("old.txt"); r.listScript { names }
        r.browser.children("docs", ""); r.await()
        names = arrayOf("new.txt", "newer.txt")
        r.clock += 11_000
        val stale = r.browser.children("docs", "")
        assertTrue(stale.loading); assertEquals(listOf("old.txt"), stale.items.map { it.name })
        r.await()
        assertEquals(listOf("new.txt", "newer.txt"), r.browser.children("docs", "").items.map { it.name })
    }

    @Test fun freshListingDoesNotAskAgain() {
        val r = Rig(); r.listScript { arrayOf("a") }
        r.browser.children("d", ""); r.await()
        r.clock += 5_000
        assertFalse(r.browser.children("d", "").loading)
        assertEquals(1, r.link.count("fs.list"))
    }

    @Test fun offlineIsAnEmptyListingWithTheFriendlyMessageAndNoRequest() {
        val r = Rig(connected = { false })
        val l = r.browser.children("docs", "")
        assertTrue(l.items.isEmpty()); assertFalse(l.loading)
        assertEquals("Your Mac is away", l.error)
        assertEquals(0, r.link.sent.size)
        assertEquals(FsErrors.OFFLINE, r.browser.rootsListing().error)
        assertEquals(FsErrors.OFFLINE, r.browser.search("x").error)
    }

    @Test fun errorsAreShownAndNotRetriedImmediately() {
        val r = Rig(); r.link.script = { Message.of("fs.error") { put("req", it.str("req")!!); put("error", "not_found") } }
        r.browser.children("d", "gone"); r.await()
        val l = r.browser.children("d", "gone")
        assertEquals("That isn't on your Mac anymore.", l.error); assertFalse(l.loading)
        assertEquals(1, r.link.count("fs.list"))
        r.clock += 4_000
        r.listScript { arrayOf("back.txt") }
        assertTrue(r.browser.children("d", "gone").loading)  // error expired: asks again
        r.await()
        assertEquals(1, r.browser.children("d", "gone").items.size)
    }

    @Test fun searchAndRecentsAreAsyncToo() {
        val r = Rig()
        r.link.script = {
            val hit = buildJsonObject { put("root", "docs"); put("path", "T/x.pdf"); put("name", "x.pdf"); put("dir", false); put("size", 9); put("mtime", 1); put("mime", "application/pdf") }
            if (it.type == "fs.search" || it.type == "fs.recent") Message.of("fs.search.result") { put("req", it.str("req")!!); put("items", buildJsonArray { add(hit) }) } else null
        }
        assertTrue(r.browser.search("pdf").loading)
        assertEquals("search", r.await().kind)
        assertEquals("T/x.pdf", r.browser.search("pdf").items.single().path)
        assertTrue(r.browser.recent().loading); assertEquals("recent", r.await().kind)
        assertEquals(1, r.browser.recent().items.size)
        // hits feed the metadata lookup, so queryDocument needs no extra round trip
        assertEquals(9L, r.browser.known("docs", "T/x.pdf")!!.size)
        assertEquals(2, r.link.sent.size)
    }

    @Test fun rootsAreRequestedOnceAndCached() {
        val r = Rig()
        r.link.script = { if (it.type == "fs.roots") Message.of("fs.roots.result") { put("req", it.str("req")!!); put("macName", "M"); put("roots", buildJsonArray { add(buildJsonObject { put("id", "d"); put("name", "Desktop"); put("writable", true) }) }) } else null }
        assertTrue(r.browser.rootsListing().loading)
        assertEquals("roots", r.await().kind)
        val l = r.browser.rootsListing()
        assertEquals(listOf("Desktop"), l.items.map { it.name }); assertTrue(r.browser.roots!!.anyWritable)
        assertEquals(1, r.link.count("fs.roots"))
    }

    @Test fun aMacThatNeverAnswersRootsIsNotAskedInALoop() {
        val r = Rig(); r.link.script = { null }
        assertTrue(r.browser.rootsListing().loading)               // asks once; no reply will come
        r.client.connectionLost()                                   // stands in for the 15 s timeout: the request fails
        assertEquals("roots", r.await().kind)
        val l = r.browser.rootsListing()                            // what the notify makes the Files app re-query
        assertFalse(l.loading); assertNotNull(l.error)
        repeat(3) { r.browser.rootsListing() }
        assertEquals(1, r.link.count("fs.roots"))
        r.clock += 61_000
        assertTrue(r.browser.rootsListing().loading)                // a minute later it tries again
        assertEquals(2, r.link.count("fs.roots"))
    }

    @Test fun lookupFindsMetadataThroughTheParentListing() {
        val r = Rig(); r.listScript { arrayOf("a.txt", "b.txt") }
        assertEquals("b.txt", r.browser.lookup("docs", "Sub/b.txt", 1_000)!!.name)
        assertEquals("Sub", r.link.sent.single().str("path"))
        assertNull(r.browser.lookup("docs", "Sub/missing.txt", 1_000))
        assertNull(Rig(connected = { false }).browser.lookup("docs", "x", 100))
    }

    @Test fun invalidateForcesARefresh() {
        val r = Rig(); r.listScript { arrayOf("a") }
        r.browser.children("d", ""); r.await()
        r.browser.invalidate("d", "")
        assertTrue(r.browser.children("d", "").loading); r.await()
        assertEquals(2, r.link.count("fs.list"))
    }
}

class FsFileCacheTest {
    private fun fill(c: FsFileCache, key: String, bytes: Int, mtime: Long) { c.target(key).writeBytes(ByteArray(bytes)); c.commit(key, mtime) }

    @Test fun reusedOnlyWhileSizeAndMtimeMatch() {
        val c = FsFileCache(tmpDir(), 1_000_000)
        val k = c.keyFor("docs", "a.txt")
        assertNull(c.lookup(k, 10, 5))
        fill(c, k, 10, 5)
        assertNotNull(c.lookup(k, 10, 5)); assertNotNull(c.lookup(k, null, null))
        assertNull(c.lookup(k, 11, 5)); assertNull(c.lookup(k, 10, 6))
        assertNotEquals(k, c.keyFor("docs", "b.txt")); assertNotEquals(k, c.keyFor("other", "a.txt"))
    }

    @Test fun truncatedCopyIsNotReused() {
        val c = FsFileCache(tmpDir(), 1_000_000); val k = "k1"
        fill(c, k, 100, 1)
        c.target(k).writeBytes(ByteArray(40))
        assertNull(c.lookup(k, null, null))
    }

    @Test fun leastRecentlyUsedGoesFirstAndNewestIsKept() {
        var t = 1_000_000L
        val c = FsFileCache(tmpDir(), 250, now = { t })
        t += 1000; fill(c, "a", 100, 1)
        t += 1000; fill(c, "b", 100, 1)
        t += 1000; assertNotNull(c.lookup("a", null, null))   // a is now newer than b
        t += 1000; fill(c, "c", 100, 1)                        // 300 > 250: evict the LRU, which is b
        assertNotNull(c.lookup("a", null, null)); assertNull(c.lookup("b", null, null)); assertNotNull(c.lookup("c", null, null))
        assertTrue(c.totalBytes() <= 250)
    }

    @Test fun anOversizedNewFileSurvivesItsOwnCommit() {
        val c = FsFileCache(tmpDir(), 50)
        fill(c, "big", 200, 1)
        assertNotNull(c.lookup("big", null, null))
    }
}

/** The whole fetch path with a real [TransferEngine] on both ends: the "Mac" sends `fs:<req>` when it sees `fs.get`. */
class FsGetTransferTest {
    private class Rig(val dir: File) {
        lateinit var phoneEngine: TransferEngine
        lateinit var macEngine: TransferEngine
        lateinit var client: FsClient
        val toMac = LinkedBlockingQueue<Message>()
        val toPhone = LinkedBlockingQueue<Message>()
        val macFile = File(dir, "mac.bin").also { f -> f.writeBytes(ByteArray(700_000).also(Random(7)::nextBytes)) }
        @Volatile var macMode = "send"   // "send" | "error" | "silent" | "cancel"
        val phoneStoreOther = object : IncomingStore {
            override fun partFile(offer: Offer) = File(dir, "other.part")
            override fun complete(offer: Offer, part: File) { error("fs file must not reach the Downloads store") }
        }
        val ledgerOther = MemoryLedger()

        init {
            client = FsClient({ if (it.type.startsWith("fs.") || it.type == "xfer.cancel") toMac.put(it) else toMac.put(it); true }, File(dir, "parts").also { it.mkdirs() })
            phoneEngine = TransferEngine({ toMac.put(it) }, FsLedger(client, ledgerOther), FsStore(client, phoneStoreOther))
            macEngine = TransferEngine({ toPhone.put(it) }, MemoryLedger(), object : IncomingStore {
                override fun partFile(offer: Offer) = File(dir, "macin.part")
                override fun complete(offer: Offer, part: File) { part.copyTo(File(dir, "macin.out"), true) }
            })
            thread(toMac) { m ->
                when {
                    m.type == "fs.get" -> when (macMode) {
                        "send" -> Thread {
                            macEngine.sendFile(Offer(FsWire.xidGet(m.str("req")!!), "file", "mac.bin", macFile.length(), "application/octet-stream"), FileFileSource(macFile))
                        }.apply { isDaemon = true }.start()
                        "error" -> toPhone.put(Message.of("fs.error") { put("req", m.str("req")!!); put("error", "not_found") })
                        "cancel" -> toPhone.put(Message.of("xfer.cancel") { put("xid", FsWire.xidGet(m.str("req")!!)) })
                    }
                    m.type.startsWith("xfer.") -> macEngine.handle(m)
                }
            }
            thread(toPhone) { m -> client.observe(m); if (!client.onMessage(m)) phoneEngine.handle(m) }
        }

        private fun thread(q: LinkedBlockingQueue<Message>, f: (Message) -> Unit) =
            Thread { while (true) f(q.take()) }.apply { isDaemon = true }.start()
    }

    @Test fun fetchedFileLandsInTheCacheTargetAndNotInDownloads() {
        val d = tmpDir(); val r = Rig(d); val target = File(d, "cache/k.bin")
        val g = r.client.get("docs", "a/b.bin", target)
        val f = g.done.get(10, TimeUnit.SECONDS)
        assertEquals(target, f)
        assertEquals(Hashing.sha256Hex(r.macFile), Hashing.sha256Hex(target))
        assertEquals(700_000L, g.total)
        assertFalse(r.ledgerOther.has("fs:${g.req}"))           // single-use xids never enter the ledger
        assertFalse(g.part.exists())
    }

    @Test fun macErrorFailsTheFetchWithItsCode() {
        val d = tmpDir(); val r = Rig(d); r.macMode = "error"
        try { r.client.get("docs", "gone", File(d, "t")).done.get(5, TimeUnit.SECONDS); fail() } catch (e: ExecutionException) { assertEquals("not_found", (e.cause as FsException).code) }
    }

    @Test fun macCancelFailsTheFetch() {
        val d = tmpDir(); val r = Rig(d); r.macMode = "cancel"
        try { r.client.get("docs", "x", File(d, "t")).done.get(5, TimeUnit.SECONDS); fail() } catch (e: ExecutionException) { assertEquals("cancelled", (e.cause as FsException).code) }
    }

    @Test fun phoneCancelTellsTheMacAndFailsTheFetch() {
        val d = tmpDir(); val r = Rig(d); r.macMode = "silent"
        val g = r.client.get("docs", "x", File(d, "t"))
        r.client.cancel(g)
        try { g.done.get(2, TimeUnit.SECONDS); fail() } catch (e: ExecutionException) { assertEquals("cancelled", (e.cause as FsException).code) }
    }

    @Test fun anOfferNobodyAskedForIsSkipped() {
        val d = tmpDir(); val r = Rig(d)
        val res = r.macEngine.sendFile(Offer("fs:unrequested", "file", "x", r.macFile.length(), "text/plain"), FileFileSource(r.macFile))
        assertEquals(SendResult.SKIPPED, res)
    }

    @Test fun normalTransfersStillUseTheirOwnStoreAndLedger() {
        val d = tmpDir(); val r = Rig(d)
        val led = FsLedger(r.client, MemoryLedger())
        led.record("photo:1:2"); led.record("fs:zzz")
        assertTrue(led.has("photo:1:2")); assertFalse(led.has("photo:9:9"))
    }
}

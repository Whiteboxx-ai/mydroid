package com.mydroid.protocol

import kotlinx.serialization.json.*
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * Pure (JVM) parts of PROTOCOL.md 9, "Mac files on the phone": wire codec, an async request client, a directory
 * browser with stale-while-revalidate caching, and the on-disk file cache. The Android `DocumentsProvider` in `:app`
 * only maps these onto cursors and file descriptors, so the logic that can be wrong is unit-tested here.
 * Nothing in here logs or exposes file names beyond returning them to the caller.
 */

data class FsRoot(val id: String, val name: String, val writable: Boolean)
data class FsRoots(val macName: String, val roots: List<FsRoot>) {
    val anyWritable: Boolean get() = roots.any { it.writable }
}

data class FsEntry(val name: String, val dir: Boolean, val size: Long, val mtime: Long, val mime: String)

/** A search or recents result. [path] is the item's full path inside [root] (it includes the name). */
data class FsHit(val root: String, val path: String, val entry: FsEntry)

class FsOutcome<out T> private constructor(val value: T?, val error: String?) {
    val ok: Boolean get() = error == null
    companion object {
        fun <T> ok(v: T) = FsOutcome(v, null)
        fun <T> fail(code: String) = FsOutcome<T>(null, code)
    }
}

/** Raised on the future of a request that failed: [code] is a protocol error ("not_found", "denied", "off") or "timeout", "offline", "cancelled". */
class FsException(val code: String) : IOException(code)

object FsErrors {
    const val OFFLINE = "Your Mac is away"

    fun message(code: String?): String = when (code) {
        "offline", "connection lost" -> OFFLINE
        "not_found" -> "That isn't on your Mac anymore."
        "denied" -> "Your Mac didn't allow that."
        "off" -> "File sharing is off on your Mac."
        "timeout" -> "Your Mac didn't answer. Try again in a moment."
        "cancelled" -> "Cancelled."
        else -> "Couldn't get that from your Mac."
    }
}

object FsWire {
    const val MAX_SEARCH = 50
    const val MAX_RECENT = 30

    fun xidGet(req: String) = "fs:$req"
    fun xidPut(req: String) = "fsput:$req"

    /** The `req` of an `fs:<req>` xid, else null. */
    fun reqOfGetXid(xid: String): String? = xid.takeIf { it.startsWith("fs:") }?.substring(3)?.takeIf { it.isNotEmpty() }

    fun isFsXid(xid: String) = xid.startsWith("fs:") || xid.startsWith("fsput:")

    fun roots(req: String) = Message.of("fs.roots") { put("req", req) }
    fun list(req: String, root: String, path: String) = Message.of("fs.list") { put("req", req); put("root", root); put("path", path) }
    fun thumb(req: String, root: String, path: String) = Message.of("fs.thumb") { put("req", req); put("root", root); put("path", path) }
    fun get(req: String, root: String, path: String) = Message.of("fs.get") { put("req", req); put("root", root); put("path", path) }
    fun put(req: String, root: String, folder: String, name: String, size: Long) = Message.of("fs.put") {
        put("req", req); put("root", root); put("path", folder); put("name", name); put("size", size)
    }
    fun search(req: String, query: String) = Message.of("fs.search") { put("req", req); put("query", query) }
    fun recent(req: String) = Message.of("fs.recent") { put("req", req) }

    private fun entryOf(o: JsonObject): FsEntry? {
        val name = (o["name"] as? JsonPrimitive)?.takeIf { it.isString }?.content?.takeIf { it.isNotEmpty() } ?: return null
        val p = { k: String -> o[k] as? JsonPrimitive }
        return FsEntry(
            name,
            p("dir")?.booleanOrNull ?: false,
            p("size")?.let { it.longOrNull ?: it.doubleOrNull?.toLong() } ?: 0L,
            p("mtime")?.let { it.longOrNull ?: it.doubleOrNull?.toLong() } ?: 0L,
            p("mime")?.takeIf { it.isString }?.content?.takeIf { it.isNotBlank() } ?: "application/octet-stream",
        )
    }

    fun parseRoots(m: Message): FsRoots = FsRoots(
        m.str("macName") ?: "",
        m.arr("roots")?.mapNotNull { e ->
            val o = e as? JsonObject ?: return@mapNotNull null
            val id = (o["id"] as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            FsRoot(id, (o["name"] as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotBlank() } ?: id, (o["writable"] as? JsonPrimitive)?.booleanOrNull ?: false)
        } ?: emptyList(),
    )

    fun parseList(m: Message): FsOutcome<List<FsEntry>> {
        m.str("error")?.let { return FsOutcome.fail(it) }
        return FsOutcome.ok(m.arr("items")?.mapNotNull { (it as? JsonObject)?.let(::entryOf) } ?: emptyList())
    }

    /**
     * `path` is the item's path within its root. A peer that sends the parent folder instead (so `path` doesn't end in
     * the name) is handled too: the name is appended.
     */
    fun parseHits(m: Message): FsOutcome<List<FsHit>> {
        m.str("error")?.let { return FsOutcome.fail(it) }
        return FsOutcome.ok(
            m.arr("items")?.mapNotNull { e ->
                val o = e as? JsonObject ?: return@mapNotNull null
                val entry = entryOf(o) ?: return@mapNotNull null
                val root = (o["root"] as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
                val raw = ((o["path"] as? JsonPrimitive)?.contentOrNull ?: "").trim('/')
                val full = when {
                    raw.isEmpty() -> entry.name
                    raw == entry.name || raw.endsWith("/" + entry.name) -> raw
                    else -> "$raw/${entry.name}"
                }
                FsHit(root, full, entry)
            } ?: emptyList(),
        )
    }
}

/** Document ids: `<macId>` is the provider root, `<macId>:<share>` a shared folder, `<macId>:<share>/a/b` anything inside. */
class FsDocId(val mac: String, val share: String?, val path: String) {
    val isMacRoot: Boolean get() = share == null
    val isShare: Boolean get() = share != null && path.isEmpty()
    val name: String get() = if (path.isEmpty()) (share ?: mac) else path.substringAfterLast('/')
    val parentPath: String get() = path.substringBeforeLast('/', "")

    fun encode(): String = when {
        share == null -> mac
        path.isEmpty() -> "$mac:${esc(share)}"
        else -> "$mac:${esc(share)}/$path"
    }

    fun child(name: String): FsDocId = FsDocId(mac, share, if (path.isEmpty()) name else "$path/$name")
    fun parent(): FsDocId? = when {
        share == null -> null
        path.isEmpty() -> FsDocId(mac, null, "")
        else -> FsDocId(mac, share, parentPath)
    }

    /** True if [other] is strictly inside this one. */
    fun contains(other: FsDocId): Boolean {
        if (other.mac != mac) return false
        if (share == null) return other.share != null
        if (other.share != share) return false
        return path.isEmpty() && other.path.isNotEmpty() || other.path.startsWith("$path/")
    }

    override fun equals(other: Any?) = other is FsDocId && other.encode() == encode()
    override fun hashCode() = encode().hashCode()
    override fun toString() = encode()

    companion object {
        private fun esc(s: String) = s.replace("%", "%25").replace("/", "%2F")
        private fun unesc(s: String) = s.replace("%2F", "/").replace("%25", "%")

        fun of(mac: String, share: String, path: String) = FsDocId(mac, share, path.trim('/'))

        /** Null for an id that isn't one of ours or has a `..` or empty segment. */
        fun parse(id: String?): FsDocId? {
            if (id.isNullOrEmpty()) return null
            val colon = id.indexOf(':')
            if (colon < 0) return FsDocId(id, null, "")
            val mac = id.substring(0, colon)
            if (mac.isEmpty()) return null
            val rest = id.substring(colon + 1)
            val slash = rest.indexOf('/')
            val share = unesc(if (slash < 0) rest else rest.substring(0, slash))
            if (share.isEmpty()) return null
            val path = if (slash < 0) "" else rest.substring(slash + 1)
            if (path.isNotEmpty() && path.split('/').any { it.isEmpty() || it == "." || it == ".." }) return null
            return FsDocId(mac, share, path)
        }
    }
}

object FsNames {
    /** A name that is safe to send: no separators or control characters, not "." or "..", at most 255 bytes of UTF-8. */
    fun sanitize(name: String): String {
        var s = name.map { if (it == '/' || it == '\\' || it == ':' || it.isISOControl()) '_' else it }.joinToString("").trim()
        if (s == "." || s == "..") s = "_"
        if (s.isEmpty()) s = "Untitled"
        while (s.toByteArray(Charsets.UTF_8).size > 255) s = s.dropLast(1)
        return s
    }

    /** [name], or "name (1).ext", "name (2).ext" ... until it isn't in [taken] (case-insensitive, like macOS). */
    fun unique(name: String, taken: Collection<String>): String {
        val lower = taken.mapTo(HashSet()) { it.lowercase() }
        if (name.lowercase() !in lower) return name
        val dot = name.lastIndexOf('.').takeIf { it > 0 } ?: name.length
        val stem = name.substring(0, dot); val ext = name.substring(dot)
        var i = 1
        while (true) {
            val c = "$stem ($i)$ext"
            if (c.lowercase() !in lower) return c
            i++
        }
    }
}

// ------------------------------------------------------------------------------------------------ client

/** A file being fetched with `fs.get`. [done] completes with the cached file, or fails with an [FsException]. */
class FsGet internal constructor(val req: String, internal val target: File, internal val part: File) {
    val xid: String get() = FsWire.xidGet(req)
    val done = CompletableFuture<File>()
    /** Size announced in the Mac's `xfer.offer`, -1 until it arrives. */
    @Volatile var total: Long = -1
        internal set
    /** Bytes received so far (the `.part` file's length). */
    val received: Long get() = if (part.exists()) part.length() else 0L
    val started: Boolean get() = total >= 0
}

/** The id of a prepared upload; the phone sends `xfer.offer` with [xid] next. */
class FsPutTicket(val req: String) {
    val xid: String get() = FsWire.xidPut(req)
}

/**
 * Sends `fs.*` requests and matches the answers by `req`. Everything is a [CompletableFuture]; replies arrive through
 * [onMessage] (from the request router's worker, never the socket reader). [send] returns false when the link is down.
 */
class FsClient(
    private val send: (Message) -> Boolean,
    private val partDir: File,
    private val newReq: () -> String = { UUID.randomUUID().toString().replace("-", "").take(12) },
    private val timers: ScheduledExecutorService = SHARED_TIMERS,
) {
    private val pending = ConcurrentHashMap<String, CompletableFuture<Message>>()
    private val gets = ConcurrentHashMap<String, FsGet>()

    private fun request(m: Message, timeoutMs: Long): CompletableFuture<Message> {
        val req = m.str("req")!!
        val f = CompletableFuture<Message>()
        // Publish the request before sending. A reply can arrive before send returns.
        pending[req] = f
        try {
            if (!send(m)) {
                pending.remove(req, f)
                f.completeExceptionally(FsException("offline"))
                return f
            }
        } catch (e: Exception) {
            pending.remove(req, f)
            throw e
        }
        val timer = timers.schedule({ if (pending.remove(req, f)) f.completeExceptionally(FsException("timeout")) }, timeoutMs, TimeUnit.MILLISECONDS)
        f.whenComplete { _, _ -> pending.remove(req, f); timer.cancel(false) }
        return f
    }

    private fun <T> typed(f: CompletableFuture<Message>, parse: (Message) -> FsOutcome<T>): CompletableFuture<FsOutcome<T>> =
        f.handle { m, ex -> if (ex != null) FsOutcome.fail((ex.cause ?: ex).let { (it as? FsException)?.code ?: "failed" }) else parse(m) }

    fun roots(timeoutMs: Long = 15_000): CompletableFuture<FsOutcome<FsRoots>> =
        typed(request(FsWire.roots(newReq()), timeoutMs)) { FsOutcome.ok(FsWire.parseRoots(it)) }

    fun list(root: String, path: String, timeoutMs: Long = 20_000): CompletableFuture<FsOutcome<List<FsEntry>>> =
        typed(request(FsWire.list(newReq(), root, path), timeoutMs), FsWire::parseList)

    fun search(query: String, timeoutMs: Long = 20_000): CompletableFuture<FsOutcome<List<FsHit>>> =
        typed(request(FsWire.search(newReq(), query), timeoutMs), FsWire::parseHits)

    fun recent(timeoutMs: Long = 20_000): CompletableFuture<FsOutcome<List<FsHit>>> =
        typed(request(FsWire.recent(newReq()), timeoutMs), FsWire::parseHits)

    /** JPEG bytes of the Mac's QuickLook thumbnail, or a failed outcome (`ok:false` is "not_found"). */
    fun thumb(root: String, path: String, timeoutMs: Long = 15_000): CompletableFuture<FsOutcome<ByteArray>> =
        typed(request(FsWire.thumb(newReq(), root, path), timeoutMs)) { m ->
            if (m.bool("ok") == true && m.payload.isNotEmpty()) FsOutcome.ok(m.payload) else FsOutcome.fail("not_found")
        }

    /** `fs.put`: completes with the ticket when the Mac answers `fs.put.ready`, else fails ("denied", "off", ...). */
    fun put(root: String, folder: String, name: String, size: Long, timeoutMs: Long = 20_000): CompletableFuture<FsOutcome<FsPutTicket>> {
        val req = newReq()
        return typed(request(FsWire.put(req, root, folder, name, size), timeoutMs)) { FsOutcome.ok(FsPutTicket(req)) }
    }

    /**
     * `fs.get`. The Mac answers by offering `fs:<req>`; the transfer engine receives it through [FsStore], which
     * moves the verified file to [target] and completes [FsGet.done]. No timeout here: the caller watches [FsGet.received]
     * (idle detection) and calls [cancel].
     */
    fun get(root: String, path: String, target: File): FsGet {
        val req = newReq()
        val g = FsGet(req, target, File(partDir, "fs_$req.part"))
        gets[req] = g
        g.done.whenComplete { _, _ -> gets.remove(req, g) }
        try {
            if (!send(FsWire.get(req, root, path))) g.done.completeExceptionally(FsException("offline"))
        } catch (e: Exception) {
            gets.remove(req, g)
            throw e
        }
        return g
    }

    /** Stops a fetch: tells the Mac and fails the future. The caller also tells its transfer engine (see `MacFiles`). */
    fun cancel(g: FsGet) {
        if (gets.remove(g.req, g) ) send(Message.of("xfer.cancel") { put("xid", g.xid) })
        g.done.completeExceptionally(FsException("cancelled"))
        runCatching { g.part.delete() }
    }

    /** True for any `fs.*` message (consumed). */
    fun onMessage(m: Message): Boolean {
        if (!m.type.startsWith("fs.")) return false
        val req = m.str("req") ?: return true
        if (m.type == "fs.error") {
            val code = m.str("error") ?: "failed"
            gets.remove(req)?.let { it.done.completeExceptionally(FsException(code)); runCatching { it.part.delete() } }
            pending.remove(req)?.completeExceptionally(FsException(code))
        } else {
            pending.remove(req)?.complete(m)
        }
        return true
    }

    /** Non-consuming: the Mac cancelled a transfer it was sending us. */
    fun observe(m: Message) {
        if (m.type != "xfer.cancel") return
        val req = FsWire.reqOfGetXid(m.str("xid") ?: return) ?: return
        gets.remove(req)?.let { it.done.completeExceptionally(FsException("cancelled")); runCatching { it.part.delete() } }
    }

    /** The link dropped: everything in flight fails with "offline". */
    fun connectionLost() {
        val ex = FsException("offline")
        pending.keys.toList().forEach { pending.remove(it)?.completeExceptionally(ex) }
        gets.keys.toList().forEach { gets.remove(it)?.let { g -> g.done.completeExceptionally(ex) } }
    }

    // --- transfer hooks (called by FsStore / FsLedger)

    /** Is there a fetch waiting for this `fs:<req>`? An unexpected offer is answered with `xfer.skip`. */
    internal fun expects(req: String) = gets.containsKey(req)

    internal fun partFor(offer: Offer): File {
        val req = FsWire.reqOfGetXid(offer.xid)
        val g = req?.let { gets[it] }
        g?.total = offer.size
        return g?.part ?: File(partDir, "fs_unexpected.part")
    }

    internal fun transferComplete(offer: Offer, part: File) {
        val g = FsWire.reqOfGetXid(offer.xid)?.let { gets.remove(it) } ?: throw IOException("nothing was waiting for this file")
        try {
            g.target.parentFile?.mkdirs()
            Files.move(part.toPath(), g.target.toPath(), StandardCopyOption.REPLACE_EXISTING)
        } catch (e: Exception) {
            g.done.completeExceptionally(FsException("failed"))
            throw IOException("couldn't save the file")
        }
        g.done.complete(g.target)
    }

    companion object {
        val SHARED_TIMERS: ScheduledExecutorService by lazy {
            Executors.newScheduledThreadPool(1) { Thread(it, "mydroid-fs-timers").apply { isDaemon = true } }
        }
    }
}

/** Routes `fs:` offers into the [FsClient] and everything else to [other], so Mac files never land in Downloads. */
class FsStore(private val fs: FsClient, private val other: IncomingStore) : IncomingStore {
    override fun partFile(offer: Offer): File = if (offer.xid.startsWith("fs:")) fs.partFor(offer) else other.partFile(offer)
    override fun complete(offer: Offer, part: File) = if (offer.xid.startsWith("fs:")) fs.transferComplete(offer, part) else other.complete(offer, part)
    override fun delivered(offer: Offer) { if (!offer.xid.startsWith("fs:")) other.delivered(offer) }
}

/** Never records `fs:` xids (they're single-use), and answers `xfer.skip` for an `fs:` offer nobody asked for. */
class FsLedger(private val fs: FsClient, private val other: Ledger) : Ledger {
    override fun has(xid: String): Boolean {
        FsWire.reqOfGetXid(xid)?.let { return !fs.expects(it) }
        return other.has(xid)
    }
    override fun record(xid: String) { if (!xid.startsWith("fs:")) other.record(xid) }
}

// ------------------------------------------------------------------------------------------------ browser

/** What a `queryChildDocuments`-style call returns right now: the best known rows, whether a refresh is in flight, and a message if it failed. */
class FsListing<T>(val items: List<T>, val loading: Boolean, val error: String?)

/**
 * Stale-while-revalidate directory cache over [FsClient]. [children], [search] and [recent] return immediately with
 * what is cached (empty the first time) and `loading = true` while a request is in flight; when it lands, [onChanged]
 * is called with the key so the provider can `notifyChange`. One request per key at a time.
 */
class FsBrowser(
    private val client: FsClient,
    private val connected: () -> Boolean,
    private val onChanged: (Key) -> Unit,
    private val now: () -> Long = System::currentTimeMillis,
    private val freshMs: Long = 20_000,
    private val errorMs: Long = 5_000,
) {
    data class Key(val kind: String, val root: String = "", val path: String = "")

    private companion object { const val ROOTS_RETRY_MS = 60_000L }

    private class Slot<T>(var items: List<T>? = null, var at: Long = 0, var error: String? = null, var errorAt: Long = 0, var inFlight: Boolean = false)

    private class View<T>(val items: List<T>?, val error: String?, val start: Boolean, val loading: Boolean)

    /** Decides, atomically, whether this call must start a refresh (marking it in flight) and what to show meanwhile. */
    private fun <T> view(slot: Slot<T>, t: Long): View<T> = synchronized(slot) {
        val recentError = slot.error != null && t - slot.errorAt < errorMs
        val start = !slot.inFlight && !recentError && (slot.items == null || t - slot.at > freshMs)
        if (start) slot.inFlight = true
        val error = if (recentError && slot.items == null) slot.error else null
        View(slot.items, error, start, slot.inFlight && error == null)
    }

    private val lists = ConcurrentHashMap<Key, Slot<FsEntry>>()
    private val hits = ConcurrentHashMap<Key, Slot<FsHit>>()
    private val meta = ConcurrentHashMap<Pair<String, String>, FsEntry>()

    @Volatile var roots: FsRoots? = null
        private set
    @Volatile private var rootsAt = 0L
    @Volatile private var rootsError: String? = null
    @Volatile private var rootsErrorAt = 0L
    private val rootsInFlight = java.util.concurrent.atomic.AtomicBoolean(false)

    fun setRoots(r: FsRoots?) { roots = r; rootsAt = now(); rootsError = null }

    /** Asks the Mac for its shared folders (one request at a time); [onChanged] with `Key("roots")` when it lands. */
    fun refreshRoots() {
        if (!connected() || !rootsInFlight.compareAndSet(false, true)) return
        client.roots().whenComplete { o, _ ->
            rootsInFlight.set(false)
            if (o != null && o.ok) { roots = o.value; rootsAt = now(); rootsError = null } else { rootsError = o?.error ?: "failed"; rootsErrorAt = now() }
            onChanged(Key("roots"))
        }
    }

    /** Shared folders now: cached, else empty with `loading` while they're requested. */
    fun rootsListing(): FsListing<FsRoot> {
        if (!connected()) return FsListing(emptyList(), false, FsErrors.OFFLINE)
        val r = roots
        // A Mac that doesn't answer (older build, asleep disk) is asked again after a minute, not on every notify.
        val backedOff = rootsError != null && now() - rootsErrorAt < ROOTS_RETRY_MS
        if ((r == null || now() - rootsAt > 5 * 60_000) && !backedOff) refreshRoots()
        return when {
            r != null -> FsListing(r.roots, false, null)
            rootsError != null && !rootsInFlight.get() -> FsListing(emptyList(), false, FsErrors.message(rootsError))
            else -> FsListing(emptyList(), true, null)
        }
    }

    fun children(root: String, path: String): FsListing<FsEntry> {
        if (!connected()) return FsListing(emptyList(), false, FsErrors.OFFLINE)
        val key = Key("ls", root, path)
        val slot = lists.getOrPut(key) { Slot() }
        val t = now()
        val v = view(slot, t)
        val (items, error, start) = Triple(v.items, v.error, v.start)
        if (start) client.list(root, path).whenComplete { o, _ ->
            synchronized(slot) {
                slot.inFlight = false
                if (o != null && o.ok) {
                    slot.items = o.value; slot.at = now(); slot.error = null
                    o.value!!.forEach { meta[root to join(path, it.name)] = it }
                } else { slot.error = o?.error ?: "failed"; slot.errorAt = now() }
            }
            onChanged(key)
        }
        return FsListing(items ?: emptyList(), v.loading, error?.let(FsErrors::message))
    }

    fun search(query: String): FsListing<FsHit> = hitsFor(Key("search", "", query)) { client.search(query) }
    fun recent(): FsListing<FsHit> = hitsFor(Key("recent")) { client.recent() }

    private fun hitsFor(key: Key, fetch: () -> CompletableFuture<FsOutcome<List<FsHit>>>): FsListing<FsHit> {
        if (!connected()) return FsListing(emptyList(), false, FsErrors.OFFLINE)
        val slot = hits.getOrPut(key) { Slot() }
        val t = now()
        val v = view(slot, t)
        val (items, error, start) = Triple(v.items, v.error, v.start)
        if (start) fetch().whenComplete { o, _ ->
            synchronized(slot) {
                slot.inFlight = false
                if (o != null && o.ok) {
                    slot.items = o.value; slot.at = now(); slot.error = null
                    o.value!!.forEach { meta[it.root to it.path] = it.entry }
                } else { slot.error = o?.error ?: "failed"; slot.errorAt = now() }
            }
            onChanged(key)
        }
        return FsListing(items ?: emptyList(), v.loading, error?.let(FsErrors::message))
    }

    /** What we last heard about [root]/[path] from a listing or search, without any I/O. */
    fun known(root: String, path: String): FsEntry? = meta[root to path]

    /**
     * Metadata for one item, asking for its parent folder's listing if needed (waits up to [waitMs]). Null when the
     * Mac isn't reachable or doesn't have it.
     */
    fun lookup(root: String, path: String, waitMs: Long): FsEntry? {
        known(root, path)?.let { return it }
        if (!connected() || path.isEmpty()) return null
        val parent = path.substringBeforeLast('/', "")
        if (!reload(root, parent, waitMs)) return null
        return known(root, path)
    }

    /** Fetches a folder now (blocking up to [waitMs]) and stores it; true if the Mac answered. */
    fun reload(root: String, path: String, waitMs: Long): Boolean {
        if (!connected()) return false
        val o = try { client.list(root, path, waitMs).get(waitMs + 500, TimeUnit.MILLISECONDS) } catch (e: Exception) { return false }
        if (!o.ok) return false
        val slot = lists.getOrPut(Key("ls", root, path)) { Slot() }
        synchronized(slot) { slot.items = o.value; slot.at = now(); slot.error = null }
        o.value!!.forEach { meta[root to join(path, it.name)] = it }
        return true
    }

    /** Forget a folder's listing (after an upload) so the next [children] asks again. */
    fun invalidate(root: String, path: String) {
        lists[Key("ls", root, path)]?.let { synchronized(it) { it.at = Long.MIN_VALUE / 2 } }
    }

    fun cachedNames(root: String, path: String): List<String> = lists[Key("ls", root, path)]?.items?.map { it.name } ?: emptyList()

    fun clear() { lists.clear(); hits.clear(); meta.clear(); roots = null; rootsError = null }

    private fun join(dir: String, name: String) = if (dir.isEmpty()) name else "$dir/$name"
}

// ------------------------------------------------------------------------------------------------ file cache

/**
 * Copies of Mac files fetched for reading, kept under [dir] with a size cap (least recently used goes first).
 * An entry is reusable only while the Mac still reports the same size and mtime. Each entry is `<key>.bin` plus a
 * small `<key>.meta` (`size mtime`) whose last-modified time is the last use.
 */
class FsFileCache(private val dir: File, private val capBytes: Long, private val now: () -> Long = System::currentTimeMillis) {
    init { dir.mkdirs() }

    fun keyFor(root: String, path: String): String =
        Hex.encode(MessageDigest.getInstance("SHA-256").digest("$root\u0000$path".toByteArray(Charsets.UTF_8))).take(32)

    fun target(key: String) = File(dir, "$key.bin")
    private fun metaFile(key: String) = File(dir, "$key.meta")

    /** The cached copy if its recorded size and mtime match; touches it. With [size] null any copy qualifies. */
    @Synchronized
    fun lookup(key: String, size: Long?, mtime: Long?): File? {
        val f = target(key); val m = metaFile(key)
        if (!f.exists() || !m.exists()) return null
        val parts = runCatching { m.readText().trim().split(' ') }.getOrNull() ?: return null
        val s = parts.getOrNull(0)?.toLongOrNull(); val t = parts.getOrNull(1)?.toLongOrNull()
        if (s == null || t == null || f.length() != s) return null
        if (size != null && s != size) return null
        if (mtime != null && t != mtime) return null
        m.setLastModified(now())
        return f
    }

    /** Call after [target] has been filled; records what the Mac said it was, then trims the cache. */
    @Synchronized
    fun commit(key: String, mtime: Long) {
        val f = target(key)
        metaFile(key).writeText("${f.length()} $mtime")
        metaFile(key).setLastModified(now())
        trim(keep = key)
    }

    fun totalBytes(): Long = dir.listFiles { x -> x.name.endsWith(".bin") }?.sumOf { it.length() } ?: 0L

    /** Delete the least recently used entries until the cache fits [capBytes]; [keep] is never removed. */
    @Synchronized
    fun trim(keep: String? = null) {
        val entries = dir.listFiles { x -> x.name.endsWith(".bin") }?.map { f ->
            val k = f.name.removeSuffix(".bin")
            Triple(k, f, metaFile(k).takeIf { it.exists() }?.lastModified() ?: 0L)
        }?.sortedBy { it.third } ?: return
        var total = entries.sumOf { it.second.length() }
        for ((k, f, _) in entries) {
            if (total <= capBytes) break
            if (k == keep) continue
            total -= f.length()
            f.delete(); metaFile(k).delete()
        }
    }

    @Synchronized
    fun clear() { dir.listFiles()?.forEach { it.delete() } }
}

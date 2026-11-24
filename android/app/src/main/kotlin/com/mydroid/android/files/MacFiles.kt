package com.mydroid.android.files

import android.app.Application
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.CancellationSignal
import android.os.OperationCanceledException
import android.provider.DocumentsContract
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.core.app.NotificationCompat
import com.mydroid.android.BuildConfig
import com.mydroid.android.Channels
import com.mydroid.android.Perms
import com.mydroid.android.R
import com.mydroid.android.data.Store
import com.mydroid.protocol.FsBrowser
import com.mydroid.protocol.FsClient
import com.mydroid.protocol.FsDocId
import com.mydroid.protocol.FsException
import com.mydroid.protocol.FsErrors
import com.mydroid.protocol.FsFileCache
import com.mydroid.protocol.FsGet
import com.mydroid.protocol.FsNames
import com.mydroid.protocol.FileFileSource
import com.mydroid.protocol.Message
import com.mydroid.protocol.Offer
import com.mydroid.protocol.SendResult
import com.mydroid.protocol.TransferEngine
import kotlinx.serialization.json.put
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

private const val TAG = "MydroidFs"

/** A document the user created through the system picker; it only exists on the Mac once its bytes have been uploaded. */
class PendingDoc(val id: FsDocId, val name: String, val mime: String)

/**
 * The Mac's shared folders as seen by the phone (PROTOCOL.md 9). Owns the request client, the directory and file
 * caches and the upload path; [MacDocumentsProvider] is a thin Android adapter over it. Created by `ConnectionManager`.
 * Logs carry counts, sizes and timings only, never names or paths.
 */
class MacFiles(
    private val app: Application,
    private val store: Store,
    send: (Message) -> Boolean,
    private val engine: () -> TransferEngine?,
    private val transferLock: Any,
    private val connected: () -> Boolean,
) {
    private val base = File(app.cacheDir, "macfiles").apply { mkdirs() }
    val client = FsClient(send, File(base, "parts").apply { mkdirs() })
    val cache = FsFileCache(File(base, "files"), CACHE_CAP)
    val browser = FsBrowser(client, connected, ::changed)
    val pending = ConcurrentHashMap<String, PendingDoc>()

    private val thumbDir = File(base, "thumbs").apply { mkdirs() }
    private val thumbMisses = ConcurrentHashMap<String, Long>()
    private val thumbSlots = Semaphore(3)
    private val inflight = ConcurrentHashMap<String, CompletableFuture<File>>()
    private val uploads = Executors.newSingleThreadExecutor { Thread(it, "mydroid-fs-up").apply { isDaemon = true } }
    private val nm = app.getSystemService(NotificationManager::class.java)
    private val lastProgress = ConcurrentHashMap<String, Long>()

    init {
        // Leftovers from a previous process: partial downloads and unsent uploads.
        File(base, "parts").listFiles()?.forEach { it.delete() }
        File(base, "up").deleteRecursively()
    }

    // ---------------------------------------------------------------- state

    val macId: String? get() = store.macId
    val macName: String get() = store.macName
    val paired: Boolean get() = store.isPaired
    val isConnected: Boolean get() = connected()

    /** The Files root is shown for a paired Mac unless the Mac said file sharing is off. Offline it stays. */
    val rootVisible: Boolean get() = store.isPaired && !store.fsOff
    val anyWritable: Boolean get() = browser.roots?.anyWritable ?: store.fsWritable

    fun writable(share: String): Boolean = browser.roots?.roots?.firstOrNull { it.id == share }?.writable ?: false

    fun docId(share: String, path: String): String? = macId?.let { FsDocId.of(it, share, path).encode() }

    // ---------------------------------------------------------------- freshness

    fun rootsUri(): Uri = DocumentsContract.buildRootsUri(AUTHORITY)

    fun notifyRoots() {
        app.contentResolver.notifyChange(rootsUri(), null)
        macId?.let { notifyChildren(it) }
    }

    private fun notifyChildren(parentDocId: String) {
        app.contentResolver.notifyChange(DocumentsContract.buildChildDocumentsUri(AUTHORITY, parentDocId), null)
    }

    /** [FsBrowser]'s "something landed" callback: persist what the root row needs and tell the Files app. */
    private fun changed(key: FsBrowser.Key) {
        val mac = macId ?: return
        try {
            when (key.kind) {
                "roots" -> {
                    browser.roots?.let { r ->
                        store.fsWritable = r.anyWritable
                        store.fsOff = r.roots.isEmpty()
                        Log.i(TAG, "roots: ${r.roots.size} shared, writable=${r.anyWritable}")
                    }
                    notifyRoots()
                }
                "ls" -> notifyChildren(FsDocId.of(mac, key.root, key.path).encode())
                "search" -> app.contentResolver.notifyChange(DocumentsContract.buildSearchDocumentsUri(AUTHORITY, mac, key.path), null)
                "recent" -> app.contentResolver.notifyChange(DocumentsContract.buildRecentDocumentsUri(AUTHORITY, mac), null)
            }
        } catch (e: Exception) {
            Log.w(TAG, "notify failed: ${e.javaClass.simpleName}")
        }
    }

    /** The session is ready: the root appears or updates, and the shared folders are asked for. */
    fun onConnected() {
        browser.refreshRoots()
        notifyRoots()
    }

    fun onDisconnected() {
        client.connectionLost()
        notifyRoots()
    }

    /** Unpaired: the root goes away and everything cached is dropped. */
    fun onUnpaired() {
        client.connectionLost()
        browser.clear(); pending.clear(); cache.clear(); thumbDir.listFiles()?.forEach { it.delete() }
        notifyRoots()
    }

    // ---------------------------------------------------------------- reading

    private fun fail(msg: String): Nothing = throw FileNotFoundException(msg)

    /**
     * The local copy of a Mac file, fetching it with `fs.get` if needed. Blocks the calling (binder) thread, honours
     * [signal], gives up when the Mac stops sending, and reuses the cached copy while size and mtime are unchanged.
     */
    fun openForRead(id: FsDocId, signal: CancellationSignal?): File {
        val share = id.share ?: fail("That's a folder")
        if (id.path.isEmpty()) fail("That's a folder")
        val key = cache.keyFor(share, id.path)
        val meta = browser.known(share, id.path) ?: if (connected()) browser.lookup(share, id.path, 4_000) else null
        cache.lookup(key, meta?.size, meta?.mtime)?.let { Log.i(TAG, "open: cache hit bytes=${it.length()}"); return it }
        if (!connected()) {
            // Offline: an older copy is better than nothing.
            cache.lookup(key, null, null)?.let { Log.i(TAG, "open: offline, stale copy bytes=${it.length()}"); return it }
            fail(FsErrors.OFFLINE)
        }
        if (meta?.dir == true) fail("That's a folder")
        val mine = CompletableFuture<File>()
        inflight.putIfAbsent(key, mine)?.let { other -> return waitFor(other, signal) }
        try {
            val f = fetch(share, id, key, meta?.mtime ?: 0L, meta?.name, signal)
            mine.complete(f)
            return f
        } catch (e: Throwable) {
            mine.completeExceptionally(e)
            throw e
        } finally {
            inflight.remove(key, mine)
        }
    }

    private fun waitFor(f: CompletableFuture<File>, signal: CancellationSignal?): File {
        val deadline = System.currentTimeMillis() + MAX_TRANSFER_MS
        while (System.currentTimeMillis() < deadline) {
            signal?.throwIfCanceled()
            try { return f.get(250, TimeUnit.MILLISECONDS) } catch (_: TimeoutException) {} catch (e: ExecutionException) { throw asIo(e.cause) }
        }
        fail(FsErrors.message("timeout"))
    }

    private fun asIo(t: Throwable?): IOException = when (t) {
        is OperationCanceledException -> throw t
        is FsException -> FileNotFoundException(FsErrors.message(t.code))
        is IOException -> t
        else -> FileNotFoundException(FsErrors.message(null))
    }

    private fun fetch(share: String, id: FsDocId, key: String, mtime: Long, name: String?, signal: CancellationSignal?): File {
        val t0 = System.currentTimeMillis()
        val g = client.get(share, id.path, cache.target(key))
        signal?.setOnCancelListener { cancelGet(g) }
        var lastBytes = 0L
        var lastMove = t0
        try {
            while (true) {
                signal?.throwIfCanceled()
                try {
                    val f = g.done.get(250, TimeUnit.MILLISECONDS)
                    cache.commit(key, mtime)
                    Log.i(TAG, "get done bytes=${f.length()} ms=${System.currentTimeMillis() - t0}")
                    return f
                } catch (_: TimeoutException) {
                } catch (e: ExecutionException) {
                    throw asIo(e.cause)
                }
                val now = System.currentTimeMillis()
                val got = g.received
                if (got != lastBytes) { lastBytes = got; lastMove = now }
                // The Mac gets longer to start (it may be waking a disk or a share) than to keep going.
                val idleLimit = if (g.started) IDLE_MS else START_MS
                if (now - lastMove > idleLimit || now - t0 > MAX_TRANSFER_MS) {
                    cancelGet(g)
                    Log.i(TAG, "get gave up after ms=${now - t0} bytes=$got")
                    fail(FsErrors.message("timeout"))
                }
                if (g.total >= PROGRESS_MIN) progress(key, name, got, g.total)
            }
        } catch (e: Throwable) {
            if (!g.done.isDone) cancelGet(g)
            throw e
        } finally {
            signal?.setOnCancelListener(null)
            nm.cancel(notifId(key))
            lastProgress.remove(key)
        }
    }

    private fun cancelGet(g: FsGet) {
        client.cancel(g)
        // The transfer engine has the half-open receive; close it the way a Mac-side cancel would.
        runCatching { engine()?.handle(Message.of("xfer.cancel") { put("xid", g.xid) }) }
    }

    private fun notifId(key: String) = 0x4d460000 or (key.hashCode() and 0xffff)

    /** One quiet, ongoing progress notification per large transfer, at most one update every 800 ms. */
    private fun progress(key: String, name: String?, got: Long, total: Long) {
        if (!Perms.canPostNotifications(app)) return
        val now = System.currentTimeMillis()
        if (now - (lastProgress[key] ?: 0L) < 800) return
        lastProgress[key] = now
        val n = NotificationCompat.Builder(app, Channels.FILES)
            .setSmallIcon(R.drawable.ic_stat_mydroid)
            .setContentTitle("Getting ${name ?: "a file"} from your Mac")
            .setProgress(1000, (got * 1000 / total.coerceAtLeast(1)).toInt().coerceIn(0, 1000), false)
            .setOngoing(true).setSilent(true).setOnlyAlertOnce(true).setCategory(NotificationCompat.CATEGORY_PROGRESS).build()
        runCatching { nm.notify(notifId(key), n) }
    }

    // ---------------------------------------------------------------- thumbnails

    /** A cached or freshly fetched JPEG thumbnail, or throws [FileNotFoundException] (the system then shows the generic icon). */
    fun thumbnail(id: FsDocId, signal: CancellationSignal?): File {
        val share = id.share ?: fail("no thumbnail")
        val entry = browser.known(share, id.path)
        val key = cache.keyFor(share, id.path) + "_" + (entry?.mtime ?: 0L)
        val f = File(thumbDir, "$key.jpg")
        if (f.exists()) { f.setLastModified(System.currentTimeMillis()); return f }
        if (!connected() || (thumbMisses[key]?.let { System.currentTimeMillis() - it < 10 * 60_000 } == true)) fail("no thumbnail")
        while (!thumbSlots.tryAcquire(250, TimeUnit.MILLISECONDS)) signal?.throwIfCanceled()
        try {
            if (f.exists()) return f
            val fut = client.thumb(share, id.path)
            val o = awaitFuture(fut, signal, 15_000) ?: fail("no thumbnail")
            if (!o.ok || o.value == null) { thumbMisses[key] = System.currentTimeMillis(); fail("no thumbnail") }
            val tmp = File(thumbDir, "$key.tmp")
            tmp.writeBytes(o.value!!)
            if (!tmp.renameTo(f)) { tmp.delete(); fail("no thumbnail") }
            trimThumbs()
            return f
        } finally {
            thumbSlots.release()
        }
    }

    private fun <T> awaitFuture(f: CompletableFuture<T>, signal: CancellationSignal?, limitMs: Long): T? {
        val deadline = System.currentTimeMillis() + limitMs
        while (System.currentTimeMillis() < deadline) {
            signal?.throwIfCanceled()
            try { return f.get(200, TimeUnit.MILLISECONDS) } catch (_: TimeoutException) {} catch (e: ExecutionException) { return null }
        }
        return null
    }

    private fun trimThumbs() {
        val files = thumbDir.listFiles { x -> x.name.endsWith(".jpg") } ?: return
        var total = files.sumOf { it.length() }
        if (total <= THUMB_CAP) return
        for (x in files.sortedBy { it.lastModified() }) {
            if (total <= THUMB_CAP) break
            total -= x.length(); x.delete()
        }
    }

    // ---------------------------------------------------------------- saving to the Mac

    /** Registers a new empty document under [parent]; nothing is sent until its bytes have been written and the file closed. */
    fun create(parent: FsDocId, mime: String, displayName: String): FsDocId {
        val share = parent.share ?: fail("Pick one of your Mac's folders first")
        if (!writable(share)) throw SecurityException("This folder is read-only. Turn on \"Allow saving to this Mac\" in Mydroid on your Mac.")
        if (mime == DocumentsContract.Document.MIME_TYPE_DIR) throw UnsupportedOperationException("Creating folders on your Mac isn't supported yet.")
        val taken = browser.cachedNames(share, parent.path) + pending.values.filter { it.id.parent() == parent }.map { it.name }
        val name = FsNames.unique(FsNames.sanitize(displayName), taken)
        val id = parent.child(name)
        pending[id.encode()] = PendingDoc(id, name, mime)
        notifyChildren(parent.encode())
        return id
    }

    private val closeThread by lazy { android.os.HandlerThread("mydroid-fs-close").apply { start() } }
    val closeHandler: android.os.Handler by lazy { android.os.Handler(closeThread.looper) }

    /** A temp file for the caller to write into; [onWritten] runs when the writer has closed it. */
    fun newUploadFile(): File = File(base, "up").apply { mkdirs() }.let { File(it, UUID.randomUUID().toString() + ".tmp") }

    fun finishUpload(doc: PendingDoc, tmp: File) {
        uploads.execute {
            val t0 = System.currentTimeMillis()
            var ok = false
            try {
                ok = upload(doc, tmp)
            } catch (e: Exception) {
                Log.w(TAG, "upload failed: ${e.javaClass.simpleName}")
            } finally {
                val size = tmp.length()
                tmp.delete()
                Log.i(TAG, "upload ok=$ok bytes=$size ms=${System.currentTimeMillis() - t0}")
                if (!ok) {
                    pending.remove(doc.id.encode())
                    doc.id.parent()?.let { notifyChildren(it.encode()) }
                    notifySaveFailed(doc.name)
                }
            }
        }
    }

    private fun upload(doc: PendingDoc, tmp: File): Boolean {
        val share = doc.id.share ?: return false
        val eng = engine()
        if (!connected() || eng == null) return false
        val folder = doc.id.parentPath
        val size = tmp.length()
        val ticket = client.put(share, folder, doc.name, size).get(25, TimeUnit.SECONDS).let { if (it.ok) it.value!! else return false }
        val offer = Offer(ticket.xid, "file", doc.name, size, doc.mime)
        val r = synchronized(transferLock) { eng.sendFile(offer, FileFileSource(tmp), timeoutMs = 60_000) }
        if (r != SendResult.DONE && r != SendResult.SKIPPED) return false
        // The Mac may have renamed it; show what's really there, then drop the placeholder.
        browser.reload(share, folder, 5_000)
        pending.remove(doc.id.encode())
        notifyChildren(doc.id.parent()!!.encode())
        return true
    }

    private fun notifySaveFailed(name: String) {
        if (!Perms.canPostNotifications(app)) return
        val n = NotificationCompat.Builder(app, Channels.FILES)
            .setSmallIcon(R.drawable.ic_stat_mydroid)
            .setContentTitle("Couldn't save $name to your Mac")
            .setContentText(if (connected()) "Try again in a moment." else FsErrors.OFFLINE)
            .setAutoCancel(true).build()
        runCatching { nm.notify(name.hashCode(), n) }
    }

    companion object {
        const val AUTHORITY = BuildConfig.APPLICATION_ID + ".macfiles"
        const val CACHE_CAP = 1L shl 30
        const val THUMB_CAP = 64L shl 20
        const val START_MS = 30_000L
        const val IDLE_MS = 45_000L
        const val MAX_TRANSFER_MS = 30 * 60_000L
        const val PROGRESS_MIN = 1L shl 20

        fun mimeFor(name: String, declared: String): String {
            if (declared.isNotBlank() && declared != "application/octet-stream") return declared
            val ext = name.substringAfterLast('.', "").lowercase()
            return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
        }

        /** Opens the system Files app at the Mac's root; falls back to just opening Files. Returns false if nothing could be opened. */
        fun openInFiles(ctx: Context, macId: String?): Boolean {
            fun tryStart(i: Intent): Boolean = try { ctx.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); true } catch (e: Exception) { false }
            if (macId != null) {
                val root = DocumentsContract.buildRootUri(AUTHORITY, macId)
                if (tryStart(Intent(Intent.ACTION_VIEW).setDataAndType(root, DocumentsContract.Root.MIME_TYPE_ITEM))) return true
                if (tryStart(Intent("android.provider.action.BROWSE").setDataAndType(root, DocumentsContract.Root.MIME_TYPE_ITEM))) return true
                val dir = DocumentsContract.buildDocumentUri(AUTHORITY, macId)
                if (tryStart(Intent(Intent.ACTION_VIEW).setDataAndType(dir, DocumentsContract.Document.MIME_TYPE_DIR))) return true
            }
            for (pkg in listOf("com.google.android.documentsui", "com.android.documentsui")) {
                ctx.packageManager.getLaunchIntentForPackage(pkg)?.let { if (tryStart(it)) return true }
            }
            return tryStart(Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*"))
        }
    }
}

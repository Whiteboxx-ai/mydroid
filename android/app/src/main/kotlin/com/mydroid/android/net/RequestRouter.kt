package com.mydroid.android.net

import android.content.Context
import android.util.Log
import com.mydroid.android.Perms
import com.mydroid.android.calls.CallHistory
import com.mydroid.android.contacts.ContactLookup
import com.mydroid.android.data.Settings
import com.mydroid.android.files.MacFiles
import com.mydroid.android.fix.Fixer
import com.mydroid.android.photos.MediaStoreSource
import com.mydroid.android.photos.PhotoLibrary
import com.mydroid.android.sms.SmsBridge
import com.mydroid.protocol.CallWire
import com.mydroid.protocol.Message
import com.mydroid.protocol.Page
import com.mydroid.protocol.PhotoItem
import com.mydroid.protocol.PhotoWire
import com.mydroid.protocol.TransferEngine
import com.mydroid.protocol.flexLong
import com.mydroid.protocol.flexLongs
import kotlinx.serialization.json.put
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

private const val TAG = "MydroidReq"

/**
 * Mac-initiated requests that read the phone (PROTOCOL.md 7.5 to 7.8): SMS history and sending, the photo library,
 * the call log and dialling. [dispatch] never blocks the caller (the socket reader): each request goes to a worker
 * and its response is sent when ready. Workers hold no thread while idle.
 *
 * A [reply] that returns false means the link is gone, so remaining work for that request is dropped.
 * The debug build drives [run] directly with its own [reply] and `enforce = false`.
 */
class RequestRouter(
    private val ctx: Context,
    private val settings: () -> Settings,
    private val reply: (Message) -> Boolean,
    private val engine: () -> TransferEngine?,
    private val transferLock: Any,
    private val macFiles: MacFiles,
) {
    val contacts = ContactLookup(ctx)
    val sms = SmsBridge(ctx, contacts, settings, reply)
    val photos = PhotoLibrary(ctx)
    val calls = CallHistory(ctx, contacts)

    private fun worker(name: String) = ThreadPoolExecutor(1, 1, 20, TimeUnit.SECONDS, LinkedBlockingQueue()) { Thread(it, name).apply { isDaemon = true } }
        .apply { allowCoreThreadTimeOut(true) }

    /** Slow provider queries (SMS, photos, calls) must not wait behind thumbnails or a download. */
    private val queries = worker("mydroid-req")
    private val sends = worker("mydroid-req-send")
    private val thumbs = worker("mydroid-req-thumbs")
    private val downloads = worker("mydroid-req-get")
    /** Answers to the phone's own `fs.*` requests (PROTOCOL.md 9): parsed here, off the socket reader. */
    private val fsReplies = worker("mydroid-req-fs")

    fun handles(type: String) = type in TYPES || type in FS_REPLIES

    fun dispatch(m: Message) {
        val pool = when {
            m.type.startsWith("fs.") -> fsReplies
            else -> poolFor(m.type)
        }
        pool.execute { run(m) }
    }

    private fun poolFor(type: String) = when (type) {
            "sms.send" -> sends
            "photos.thumbs.get" -> thumbs
            "photos.get" -> downloads
            else -> queries
        }

    /** Runs one request on the calling thread. With [enforce] false the `settings` switches are not consulted (permissions still are). */
    fun run(m: Message, enforce: Boolean = true) {
        val t0 = System.nanoTime()
        try {
            when (m.type) {
                "sms.threads.get" -> sms.threads(m, enforce)
                "sms.messages.get" -> sms.messages(m, enforce)
                "sms.send" -> sms.send(m, enforce)
                "photos.list" -> photosList(m)
                "photos.thumbs.get" -> photosThumbs(m)
                "photos.get" -> photosGet(m)
                "calls.list" -> callsList(m)
                "call.dial" -> callDial(m)
                else -> if (m.type.startsWith("fs.")) macFiles.client.onMessage(m)
            }
        } catch (e: Exception) {
            Log.w(TAG, "${m.type} failed: ${e.javaClass.simpleName}")
        }
        Log.i(TAG, "${m.type} done ms=${(System.nanoTime() - t0) / 1_000_000}")
    }

    // ---------------------------------------------------------------- photos (7.7)

    private fun photoAccess() = Perms.hasPhotoAccess(ctx)

    private fun photosList(m: Message) {
        if (!photoAccess()) { reply(PhotoWire.page(Page(emptyList<PhotoItem>(), false), "permission")); return }
        val page = photos.list(PhotoWire.album(m.str("album")), PhotoWire.limit(m.int("limit")), m.flexLong("before"))
        reply(PhotoWire.page(page))
        Log.i(TAG, "photos.page items=${page.items.size} more=${page.more}")
    }

    private fun photosThumbs(m: Message) {
        val ids = m.flexLongs("ids").distinct().take(PhotoWire.MAX_THUMBS)
        var made = 0
        var bytes = 0
        for (id in ids) {
            val jpeg = if (photoAccess()) runCatching { photos.thumb(id) }.getOrNull() else null
            if (jpeg != null) { made++; bytes += jpeg.size }
            if (!reply(PhotoWire.thumb(id, jpeg))) break
        }
        Log.i(TAG, "photos.thumb requested=${ids.size} made=$made bytes=$bytes")
    }

    /** Offers the original as `lib:<id>` through the normal transfer engine. Not queued, not in the auto-sync ledger. */
    private fun photosGet(m: Message) {
        val id = m.flexLong("id") ?: return
        val xid = PhotoWire.libraryXid(id)
        fun cancel() { reply(Message.of("xfer.cancel") { put("xid", xid) }) }
        val eng = engine()
        if (eng == null || !photoAccess()) return cancel()
        val src = try { MediaStoreSource(ctx, photos.uri(id)) } catch (e: Exception) { return cancel() }
        val offer = photos.offerFor(id, src.size) ?: return cancel()
        val r = synchronized(transferLock) { eng.sendFile(offer, src) }
        Log.i(TAG, "photos.get size=${offer.size} result=$r")
    }

    // ---------------------------------------------------------------- calls (7.8)

    private fun callsList(m: Message) {
        if (!calls.canRead()) { reply(CallWire.page(emptyList(), "permission")); return }
        val items = calls.list(CallWire.limit(m.int("limit")))
        reply(CallWire.page(items))
        Log.i(TAG, "calls.page items=${items.size}")
    }

    private fun callDial(m: Message) {
        val err = calls.dial(m.str("number"))
        Log.i(TAG, "call.dial result=${err ?: "placed"}")
        if (err == "permission") Fixer.post(ctx, "dial")
    }

    private companion object {
        val FS_REPLIES = setOf("fs.roots.result", "fs.list.result", "fs.thumb.result", "fs.search.result", "fs.put.ready", "fs.error")
        val TYPES = setOf("sms.threads.get", "sms.messages.get", "sms.send", "photos.list", "photos.thumbs.get", "photos.get", "calls.list", "call.dial")
    }
}

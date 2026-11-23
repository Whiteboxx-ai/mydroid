package com.mydroid.android.photos

import android.content.Context
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import com.mydroid.android.Perms
import com.mydroid.android.data.Store
import com.mydroid.protocol.FileSource
import com.mydroid.protocol.Offer
import com.mydroid.protocol.SendResult
import com.mydroid.protocol.TransferEngine
import java.io.FileInputStream
import java.io.IOException
import java.io.InputStream

/** Original-bytes source for a MediaStore image (setRequireOriginal when we may read location). */
class MediaStoreSource(private val ctx: Context, uri: Uri, original: Boolean = true) : FileSource {
    private val target: Uri = if (original && Build.VERSION.SDK_INT >= 29 && Perms.canReadOriginals(ctx)) {
        runCatching { MediaStore.setRequireOriginal(uri) }.getOrDefault(uri)
    } else {
        uri
    }
    private val fallback = uri

    private fun openFd(): ParcelFileDescriptor =
        try {
            ctx.contentResolver.openFileDescriptor(target, "r")
        } catch (e: Exception) {
            if (target != fallback) ctx.contentResolver.openFileDescriptor(fallback, "r") else throw e
        } ?: throw IOException("cannot open $fallback")

    override val size: Long = openFd().use { it.statSize }

    override fun open(offset: Long): InputStream {
        val fd = openFd()
        val ins = FileInputStream(fd.fileDescriptor)
        if (offset > 0) ins.channel.position(offset)
        return object : InputStream() {
            override fun read() = ins.read()
            override fun read(b: ByteArray, off: Int, len: Int) = ins.read(b, off, len)
            override fun close() {
                ins.close(); fd.close()
            }
        }
    }
}

/** Finds new camera photos and uploads the queue, one offer at a time. */
class PhotoSync(private val ctx: Context, private val store: Store, val queue: PhotoQueue) {
    private val handler = Handler(Looper.getMainLooper())
    private var observer: ContentObserver? = null
    @Volatile var onNewPhotos: (() -> Unit)? = null

    private val debouncedScan = Runnable {
        Thread { if (scan() > 0) onNewPhotos?.invoke() }.start()
    }

    fun startObserving() {
        if (observer != null) return
        val o = object : ContentObserver(handler) {
            override fun onChange(selfChange: Boolean) {
                handler.removeCallbacks(debouncedScan)
                handler.postDelayed(debouncedScan, 2500) // let the camera finish writing
            }
        }
        ctx.contentResolver.registerContentObserver(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true, o)
        observer = o
    }

    fun stopObserving() {
        observer?.let { ctx.contentResolver.unregisterContentObserver(it) }
        observer = null
        handler.removeCallbacks(debouncedScan)
    }

    /** Queue camera photos added after pairing (never the whole history). Returns the number newly queued. */
    @Synchronized
    fun scan(): Int {
        if (!Perms.hasPhotoAccess(ctx)) return 0
        val pairedSec = store.pairedAt / 1000
        // A screenshot is inserted pending and finished later, after newer rows may already have advanced the mark;
        // look back two minutes and let the queue's seen-set dedupe.
        val mark = maxOf(store.photoScanMark - 120, pairedSec)
        val found = ArrayList<QueuedPhoto>()
        var maxAdded = store.photoScanMark
        val proj = arrayOf(
            MediaStore.Images.Media._ID, MediaStore.Images.Media.DISPLAY_NAME, MediaStore.Images.Media.MIME_TYPE,
            MediaStore.Images.Media.SIZE, MediaStore.Images.Media.DATE_ADDED, MediaStore.Images.Media.DATE_MODIFIED,
            MediaStore.Images.Media.DATE_TAKEN,
        )
        try {
            ctx.contentResolver.query(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI, proj,
                // Camera (DCIM/Camera, DCIM/Screenshots) and screenshots (Pictures/Screenshots on Pixel/OnePlus/Samsung).
                // Never Pictures/WhatsApp, Download/ and other app folders. IS_PENDING=0 skips half-written files.
                "${MediaStore.Images.Media.DATE_ADDED} > ? AND ${MediaStore.Images.Media.IS_PENDING} = 0 AND " +
                    "(${MediaStore.Images.Media.RELATIVE_PATH} LIKE ? OR ${MediaStore.Images.Media.RELATIVE_PATH} LIKE ?)" +
                    // settings.screenshots (PROTOCOL.md 7.2): off means camera photos only.
                    if (store.settings.screenshots) "" else
                        " AND ${MediaStore.Images.Media.RELATIVE_PATH} NOT LIKE '%Screenshot%' AND ${MediaStore.Images.Media.DISPLAY_NAME} NOT LIKE 'Screenshot%'",
                arrayOf(mark.toString(), "DCIM/%", "Pictures/Screenshot%"),
                "${MediaStore.Images.Media.DATE_ADDED} ASC",
            )?.use { c ->
                while (c.moveToNext()) {
                    val added = c.getLong(4)
                    maxAdded = maxOf(maxAdded, added)
                    val size = c.getLong(3)
                    if (size <= 0) continue
                    found += QueuedPhoto(
                        id = c.getLong(0), modified = c.getLong(5), name = c.getString(1) ?: "photo.jpg",
                        mime = c.getString(2) ?: "image/jpeg", taken = c.getLong(6).takeIf { it > 0 } ?: (added * 1000), size = size,
                    )
                }
            }
        } catch (e: SecurityException) {
            return 0
        }
        if (maxAdded > store.photoScanMark) store.photoScanMark = maxAdded
        return queue.addNew(found).also { if (found.isNotEmpty()) android.util.Log.i("MydroidPhoto", "scan: candidates=${found.size} newlyQueued=$it") }
    }

    /**
     * Offers queued photos one at a time while [active]. Returns normally when the queue is empty
     * or something failed; throws IOException if the connection dropped (items stay queued).
     */
    fun drain(engine: TransferEngine, lock: Any, onSynced: () -> Unit = {}, active: () -> Boolean) {
        var failures = 0
        while (active()) {
            val p = queue.peek() ?: return
            val src = try {
                MediaStoreSource(ctx, p.uri)
            } catch (e: Exception) {
                queue.remove(p.xid) // deleted or unreadable
                continue
            }
            val offer = Offer(p.xid, "photo", p.name, src.size, p.mime, p.taken)
            val r = synchronized(lock) { engine.sendFile(offer, src) }
            when (r) {
                SendResult.DONE, SendResult.SKIPPED -> { queue.remove(p.xid); onSynced(); android.util.Log.i("MydroidPhoto", "sent ${p.xid} size=${p.size} result=$r") }
                else -> {
                    queue.moveToBack(p.xid)
                    if (++failures >= 3) return
                }
            }
        }
    }
}

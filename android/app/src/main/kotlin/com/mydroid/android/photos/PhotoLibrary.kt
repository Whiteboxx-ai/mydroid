package com.mydroid.android.photos

import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import android.provider.MediaStore
import android.util.LruCache
import android.util.Size
import com.mydroid.protocol.Offer
import com.mydroid.protocol.Page
import com.mydroid.protocol.Paging
import com.mydroid.protocol.PhotoItem
import com.mydroid.protocol.PhotoWire
import java.io.ByteArrayOutputStream

/**
 * PROTOCOL.md 7.7: browse the phone's images on demand. Reads MediaStore only; nothing here touches the auto-sync
 * queue or its ledger. Call from a worker thread. Never logs names or content.
 */
class PhotoLibrary(private val ctx: Context) {
    private val cr = ctx.contentResolver
    private val base = MediaStore.Images.Media.EXTERNAL_CONTENT_URI

    /** Thumbnails already made, by id, bounded by bytes (a thumbnail is ~10-30 KB). */
    private val thumbs = object : LruCache<Long, ByteArray>(6 * 1024 * 1024) {
        override fun sizeOf(key: Long, value: ByteArray) = value.size
    }

    private fun albumClause(album: String): String = when (album) {
        "camera" -> " AND ${MediaStore.Images.Media.RELATIVE_PATH} LIKE 'DCIM/Camera%'"
        "screenshots" -> " AND (${MediaStore.Images.Media.RELATIVE_PATH} LIKE '%Screenshot%' OR ${MediaStore.Images.Media.DISPLAY_NAME} LIKE 'Screenshot%')"
        else -> ""
    }

    private val proj = arrayOf(
        MediaStore.Images.Media._ID, MediaStore.Images.Media.DISPLAY_NAME, MediaStore.Images.Media.DATE_TAKEN, MediaStore.Images.Media.DATE_ADDED,
        MediaStore.Images.Media.WIDTH, MediaStore.Images.Media.HEIGHT, MediaStore.Images.Media.SIZE, MediaStore.Images.Media.MIME_TYPE,
        MediaStore.Images.Media.RELATIVE_PATH, MediaStore.Images.Media.ORIENTATION,
    )

    private fun rows(sel: String, args: List<String>, sort: String, cap: Int): List<PhotoItem> {
        val out = ArrayList<PhotoItem>()
        val c = try {
            cr.query(base, proj, sel, args.toTypedArray(), "$sort LIMIT $cap")
        } catch (e: IllegalArgumentException) {
            cr.query(base, proj, sel, args.toTypedArray(), sort)
        }
        c?.use {
            while (it.moveToNext() && out.size < cap) {
                val (w, h) = PhotoWire.displaySize(it.getInt(4), it.getInt(5), it.getInt(9))
                out += PhotoItem(
                    id = it.getLong(0), name = it.getString(1) ?: "photo.jpg",
                    taken = PhotoWire.effectiveDate(if (it.isNull(2)) null else it.getLong(2), it.getLong(3)),
                    w = w, h = h, size = it.getLong(6), mime = it.getString(7) ?: "image/jpeg",
                    album = PhotoWire.albumOf(it.getString(8), it.getString(1)),
                )
            }
        }
        return out
    }

    /**
     * Newest first by DATE_TAKEN, falling back to DATE_ADDED for photos that have none. Those two groups can't be
     * ordered by one provider sort, so each is queried on its own and merged here.
     */
    fun list(album: String, limit: Int, before: Long?): Page<PhotoItem> {
        val cap = limit + Paging.TIE_EXTRA
        val extra = albumClause(album)
        val pending = "${MediaStore.Images.Media.IS_PENDING} = 0"
        val taken = MediaStore.Images.Media.DATE_TAKEN
        val added = MediaStore.Images.Media.DATE_ADDED

        val a = rows("$pending AND $taken > 0${if (before != null) " AND $taken < ?" else ""}$extra",
            if (before != null) listOf(before.toString()) else emptyList(), "$taken DESC", cap)
        // DATE_ADDED is in seconds: `sec * 1000 < before` is `sec < ceil(before / 1000)`.
        val b = rows("$pending AND ($taken IS NULL OR $taken <= 0)${if (before != null) " AND $added < ?" else ""}$extra",
            if (before != null) listOf(((before + 999) / 1000).toString()) else emptyList(), "$added DESC", cap)
        val merged = Paging.merge(a, b) { it.taken }
        return Paging.page(merged, limit, { it.taken }, moreBeyondInput = a.size >= cap || b.size >= cap)
    }

    fun uri(id: Long): Uri = ContentUris.withAppendedId(base, id)

    /** Name, mime and date for a library download (the size comes from the opened source), or null if the photo is gone. */
    fun offerFor(id: Long, size: Long): Offer? {
        val p = arrayOf(MediaStore.Images.Media.DISPLAY_NAME, MediaStore.Images.Media.MIME_TYPE, MediaStore.Images.Media.DATE_TAKEN, MediaStore.Images.Media.DATE_ADDED, MediaStore.Images.Media.IS_PENDING)
        cr.query(uri(id), p, null, null, null)?.use { c ->
            if (!c.moveToFirst() || c.getInt(4) != 0) return null
            return Offer(PhotoWire.libraryXid(id), "photo", c.getString(0) ?: "photo.jpg", size, c.getString(1) ?: "image/jpeg",
                PhotoWire.effectiveDate(if (c.isNull(2)) null else c.getLong(2), c.getLong(3)))
        }
        return null
    }

    /** JPEG of about [PhotoWire.THUMB_PX] px on the long edge, or null if it can't be made. */
    fun thumb(id: Long): ByteArray? {
        thumbs.get(id)?.let { return it }
        val u = uri(id)
        val bmp = try {
            cr.loadThumbnail(u, Size(PhotoWire.THUMB_PX, PhotoWire.THUMB_PX), null)
        } catch (e: Exception) {
            decodeFallback(u)
        } ?: return null
        val jpeg = encode(bmp) ?: return null
        thumbs.put(id, jpeg)
        return jpeg
    }

    private fun decodeFallback(u: Uri): Bitmap? = try {
        ImageDecoder.decodeBitmap(ImageDecoder.createSource(cr, u)) { dec, info, _ ->
            val (w, h) = PhotoWire.fitSize(info.size.width, info.size.height)
            dec.setTargetSize(w, h)
            dec.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }
    } catch (e: Exception) {
        null
    }

    private fun encode(src: Bitmap): ByteArray? {
        var bmp = if (src.config == Bitmap.Config.HARDWARE) src.copy(Bitmap.Config.ARGB_8888, false) ?: return null else src
        val (w, h) = PhotoWire.fitSize(bmp.width, bmp.height)
        if (w != bmp.width || h != bmp.height) bmp = Bitmap.createScaledBitmap(bmp, w, h, true)
        val out = ByteArrayOutputStream(24 * 1024)
        return if (bmp.compress(Bitmap.CompressFormat.JPEG, PhotoWire.THUMB_QUALITY, out)) out.toByteArray() else null
    }
}

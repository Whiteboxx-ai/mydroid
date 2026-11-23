package com.mydroid.android.files

import android.annotation.SuppressLint
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.os.Environment
import android.provider.MediaStore
import androidx.core.app.NotificationCompat
import com.mydroid.android.Channels
import com.mydroid.android.Perms
import com.mydroid.android.R
import com.mydroid.protocol.IncomingStore
import com.mydroid.protocol.Ledger
import com.mydroid.protocol.Offer
import java.io.File
import java.io.IOException

/** Files from the Mac land in Download/Mydroid/ through MediaStore, with a notification that opens them. */
class IncomingFiles(private val ctx: Context, private val onSaved: (name: String, size: Long) -> Unit = { _, _ -> }) : IncomingStore {
    private val dir = File(ctx.cacheDir, "incoming").apply { mkdirs() }

    override fun partFile(offer: Offer): File =
        File(dir, offer.xid.replace(Regex("[^A-Za-z0-9._-]"), "_") + ".part")

    @SuppressLint("MissingPermission")
    override fun complete(offer: Offer, part: File) {
        val cr = ctx.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, offer.name)
            put(MediaStore.Downloads.MIME_TYPE, offer.mime)
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/Mydroid")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = cr.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: throw IOException("Couldn't create the file")
        try {
            cr.openOutputStream(uri)!!.use { out -> part.inputStream().use { it.copyTo(out) } }
            cr.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
        } catch (e: Exception) {
            cr.delete(uri, null, null)
            throw IOException(e.message ?: "Couldn't save the file")
        }
        onSaved(offer.name, offer.size)
        val view = Intent(Intent.ACTION_VIEW).setDataAndType(uri, offer.mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        val pi = PendingIntent.getActivity(ctx, offer.xid.hashCode(), view, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val n = NotificationCompat.Builder(ctx, Channels.FILES)
            .setSmallIcon(R.drawable.ic_stat_mydroid)
            .setContentTitle("Got ${offer.name}")
            .setContentText("From your Mac · Downloads/Mydroid")
            .setContentIntent(pi).setAutoCancel(true).build()
        if (Perms.canPostNotifications(ctx)) ctx.getSystemService(NotificationManager::class.java).notify(offer.xid.hashCode(), n)
    }
}

/** Ledger of completed incoming xids, persisted so a re-offered file is skipped. */
class FileLedger(context: Context) : Ledger {
    private val file = File(context.filesDir, "incoming_ledger.txt")
    private val set = LinkedHashSet<String>().also { s -> if (file.exists()) s += file.readLines().takeLast(500) }
    @Synchronized override fun has(xid: String) = xid in set
    @Synchronized override fun record(xid: String) {
        if (set.add(xid)) runCatching { file.appendText(xid + "\n") }
    }
}

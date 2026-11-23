package com.mydroid.android.debug

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.util.Log
import com.mydroid.android.manager

/** Debug builds only: `am broadcast -n com.mydroid.android/.debug.DebugReceiver -a com.mydroid.android.debug.MUTE --es pkgs com.android.shell`. */
class DebugReceiver : BroadcastReceiver() {
    private companion object { var session: MediaSession? = null }

    override fun onReceive(c: Context, i: Intent) {
        if (i.action == "com.mydroid.android.debug.MUTE") {
            val pkgs = (i.getStringExtra("pkgs") ?: "").split(',').filter { it.isNotBlank() }.toSet()
            Log.i("MydroidDebug", "mute override n=${pkgs.size}")
            c.manager().notifs.setMuted(pkgs)
        } else if (i.action == "com.mydroid.android.debug.CLEAN_SHELL") {
            // Removes only notifications posted by the adb shell during tests.
            val l = c.manager().notifs.listener ?: return
            l.activeNotifications.filter { it.packageName == "com.android.shell" }.forEach { l.cancelNotification(it.key) }
        } else if (i.action == "com.mydroid.android.debug.MEDIA_TEST") {
            // A synthetic, silent session with made-up metadata (never the user's real players).
            val m = c.manager()
            val state = i.getStringExtra("state") ?: "playing"
            val s = session ?: MediaSession(c.applicationContext, "mydroid-test").also { session = it; it.isActive = true }
            if (state == "release") { s.release(); session = null; m.media.allowOwn = false; m.media.refresh(); return }
            val first = !m.media.allowOwn
            m.media.allowOwn = true
            s.setMetadata(MediaMetadata.Builder().putString(MediaMetadata.METADATA_KEY_TITLE, "Debug Track")
                .putString(MediaMetadata.METADATA_KEY_ARTIST, "Debug Artist").putString(MediaMetadata.METADATA_KEY_ALBUM, "Debug Album")
                .putLong(MediaMetadata.METADATA_KEY_DURATION, 200_000)
                .putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, Bitmap.createBitmap(512, 512, Bitmap.Config.ARGB_8888).also { it.eraseColor(0xFF3366CC.toInt()) }).build())
            s.setPlaybackState(PlaybackState.Builder()
                .setActions(PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_SEEK_TO or PlaybackState.ACTION_SKIP_TO_NEXT)
                .setState(if (state == "paused") PlaybackState.STATE_PAUSED else PlaybackState.STATE_PLAYING, i.getLongExtra("pos", 5_000), 1f).build())
            s.setCallback(object : MediaSession.Callback() {
                override fun onPlay() { Log.i("MydroidDebug", "test session got play") }
                override fun onPause() { Log.i("MydroidDebug", "test session got pause") }
                override fun onSeekTo(pos: Long) { Log.i("MydroidDebug", "test session got seek") }
            })
            if (first) m.media.refresh()
        } else if (i.action == "com.mydroid.android.debug.LIB_TEST") {
            val pending = goAsync()
            Thread({ try { LibraryProbe.run(c.applicationContext) } finally { pending.finish() } }, "mydroid-libprobe").start()
        } else if (i.action == "com.mydroid.android.debug.FS_TEST") {
            // Queries our own provider in-process (the shell may not hold MANAGE_DOCUMENTS) and logs counts and flags only.
            val pending = goAsync()
            Thread({
                try {
                    val cr = c.contentResolver
                    val auth = "com.mydroid.android.macfiles"
                    val roots = cr.query(android.provider.DocumentsContract.buildRootsUri(auth), null, null, null, null)
                    var mac: String? = null
                    roots?.use { r ->
                        Log.i("MydroidFs", "test roots rows=${r.count}")
                        if (r.moveToFirst()) {
                            mac = r.getString(r.getColumnIndexOrThrow(android.provider.DocumentsContract.Root.COLUMN_DOCUMENT_ID))
                            Log.i("MydroidFs", "test root flags=0x${Integer.toHexString(r.getInt(r.getColumnIndexOrThrow(android.provider.DocumentsContract.Root.COLUMN_FLAGS)))} summaryIsViaMydroid=${r.getString(r.getColumnIndexOrThrow(android.provider.DocumentsContract.Root.COLUMN_SUMMARY)) == "via Mydroid"}")
                        }
                    }
                    val id = mac ?: return@Thread
                    val uri = android.provider.DocumentsContract.buildChildDocumentsUri(auth, id)
                    repeat(2) { n ->
                        cr.query(uri, null, null, null, null)?.use { q ->
                            val e = q.extras
                            Log.i("MydroidFs", "test children#$n rows=${q.count} loading=${e.getBoolean(android.provider.DocumentsContract.EXTRA_LOADING)} error=${e.getString(android.provider.DocumentsContract.EXTRA_ERROR) != null}")
                        }
                        if (n == 0) Thread.sleep(3_000)
                    }
                } catch (e: Exception) {
                    Log.w("MydroidFs", "test failed: ${e.javaClass.simpleName}")
                } finally { pending.finish() }
            }, "mydroid-fstest").start()
        } else if (i.action == "com.mydroid.android.debug.SPOTIFY_CHECK") {
            // Probes Spotify's live session (if one is active) and logs the last Spotify check line under tag Mydroid.
            // Read with: adb logcat -s Mydroid. Fixed labels only; never ids, titles or artists.
            val pending = goAsync()
            Thread({
                try { Log.i("Mydroid", "debug " + c.manager().notifs.mediaProbe.checkNow()) } finally { pending.finish() }
            }, "mydroid-spotifycheck").start()
        } else if (i.action == "com.mydroid.android.debug.NOTIF_OPEN" || i.action == "com.mydroid.android.debug.NOTIF_OPEN_TEST") {
            // NOTIF_OPEN --es key <sbn key>   or   --es tag <tag> [--es pkg <package>]  runs notif.open's handler and logs the outcome.
            // NOTIF_OPEN_TEST [--ez cancel true] posts our own test notification (tag mydroid-open-test) whose tap opens
            // OpenTestActivity (or, with cancel, carries a cancelled PendingIntent to exercise the fallback), then opens it.
            val pending = goAsync()
            val test = i.action!!.endsWith("TEST")
            val cancel = i.getBooleanExtra("cancel", false)
            val tagArg = if (test) "mydroid-open-test" else i.getStringExtra("tag")
            val pkgArg = i.getStringExtra("pkg") ?: c.packageName
            val keyArg = i.getStringExtra("key")
            Thread({
                try {
                    val m = c.manager()
                    if (test) {
                        val pi = android.app.PendingIntent.getActivity(c, 7, Intent(c, OpenTestActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_CANCEL_CURRENT)
                        val n = androidx.core.app.NotificationCompat.Builder(c, com.mydroid.android.Channels.LINKS)
                            .setSmallIcon(com.mydroid.android.R.drawable.ic_stat_mydroid).setContentTitle("Open test").setContentText("Debug notification")
                            .setContentIntent(pi).build()
                        if (cancel) pi.cancel()
                        c.getSystemService(android.app.NotificationManager::class.java).notify("mydroid-open-test", 4999, n)
                        Thread.sleep(1_500)
                    }
                    val key = keyArg ?: m.notifs.listener?.activeNotifications?.firstOrNull { it.tag == tagArg && it.packageName == pkgArg }?.key
                    if (key == null) { Log.i("MydroidDebug", "open: no such notification"); return@Thread }
                    val latch = java.util.concurrent.CountDownLatch(1)
                    m.notifs.open(key) { r ->
                        Log.i("MydroidDebug", "open result ok=${r.bool("ok")} hasError=${r.str("error") != null} note=${r.str("note")}")
                        latch.countDown()
                    }
                    latch.await(10, java.util.concurrent.TimeUnit.SECONDS)
                    Thread.sleep(500)
                    if (test) c.getSystemService(android.app.NotificationManager::class.java).cancel("mydroid-open-test", 4999)
                } finally { pending.finish() }
            }, "mydroid-opentest").start()
        } else if (i.action == "com.mydroid.android.debug.MEDIA") {
            val m = c.manager()
            Log.i("MydroidDebug", "media override on=${i.getBooleanExtra("on", true)}")
            m.debugApply(m.settings.copy(media = i.getBooleanExtra("on", true)))
        }
    }
}

package com.mydroid.android.notif

import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSession
import android.media.session.MediaSessionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import com.mydroid.protocol.MediaIds

/**
 * Media-session metadata for notifications (`notif.posted.media`, PROTOCOL.md 13.1), and the Spotify check.
 *
 * The check answers one question: does Spotify's MediaSession expose a track id (`METADATA_KEY_MEDIA_ID` /
 * `METADATA_KEY_MEDIA_URI`) in a form the Mac could open? Whenever com.spotify.music posts or updates its media
 * notification, or its session's metadata changes, one line goes to logcat under tag `Mydroid`:
 * `spotify-mediaid present=<bool> scheme=<spotify:track|spotify:episode|http|other|none> field=<MEDIA_ID|MEDIA_URI|none>`.
 * Never the id, title or artist. The last line is also kept in [last] for the debug broadcast.
 * Everything runs on its own thread, never the main one.
 */
class MediaIdProbe(private val ctx: Context) {
    class Meta(val title: String, val artist: String, val album: String?, val mediaId: String?)

    private val thread by lazy { HandlerThread("mydroid-mediaid").apply { isDaemon = true; start() } }
    private val handler by lazy { Handler(thread.looper) }
    private val msm = ctx.getSystemService(MediaSessionManager::class.java)
    private var component: ComponentName? = null
    private val watched = HashMap<MediaSession.Token, Pair<MediaController, MediaController.Callback>>()
    private var lastAt = 0L
    private var lastLine = ""

    private val sessionsListener = MediaSessionManager.OnActiveSessionsChangedListener { list -> sync(list.orEmpty()) }

    /** Notification access came (listener connected) or went. Idempotent. */
    fun setListener(c: ComponentName?) {
        handler.post {
            if (c == component) return@post
            detach()
            component = c
            if (c != null) attach(c)
        }
    }

    private fun attach(c: ComponentName) {
        try {
            msm.addOnActiveSessionsChangedListener(sessionsListener, c, handler)
            sync(msm.getActiveSessions(c))
        } catch (e: SecurityException) {
            Log.i(TAG, "spotify-mediaid watch waits for notification access")
        }
    }

    private fun detach() {
        runCatching { msm.removeOnActiveSessionsChangedListener(sessionsListener) }
        watched.values.forEach { (c, cb) -> runCatching { c.unregisterCallback(cb) } }
        watched.clear()
    }

    private fun sync(list: List<MediaController>) {
        val spotify = list.filter { it.packageName == SPOTIFY }
        val tokens = spotify.map { it.sessionToken }.toSet()
        watched.keys.filter { it !in tokens }.forEach { t -> watched.remove(t)?.let { (c, cb) -> runCatching { c.unregisterCallback(cb) } } }
        for (c in spotify) {
            if (c.sessionToken in watched) continue
            val cb = object : MediaController.Callback() {
                override fun onMetadataChanged(metadata: MediaMetadata?) { if (metadata != null) report(metadata) }
            }
            c.registerCallback(cb, handler)
            watched[c.sessionToken] = c to cb
            c.metadata?.let(::report) // a session that was already playing when we attached
        }
    }

    /** A Spotify media notification was posted or updated. */
    fun onNotification(n: Notification) {
        handler.post { controllerOf(n)?.metadata?.let(::report) }
    }

    /** Debug broadcast: probe Spotify's live session now (if any) and log the last result. Returns it. */
    fun checkNow(): String {
        val c = component?.let { runCatching { msm.getActiveSessions(it) }.getOrNull() }?.firstOrNull { it.packageName == SPOTIFY }
        c?.metadata?.let { md -> synchronized(this) { lastAt = 0L }; report(md) }
        return last
    }

    private fun report(md: MediaMetadata) {
        val line = MediaIds.pick(md.getString(MediaMetadata.METADATA_KEY_MEDIA_ID), md.getString(MediaMetadata.METADATA_KEY_MEDIA_URI)).logLine()
        val now = System.currentTimeMillis()
        synchronized(this) {
            last = line
            // The notification and the metadata callback usually fire together for one track change.
            if (line == lastLine && now - lastAt < 1_500) return
            lastLine = line; lastAt = now
        }
        Log.i(LOG_TAG, line)
    }

    companion object {
        const val SPOTIFY = "com.spotify.music"
        /** `adb logcat -s Mydroid` shows the Spotify check. */
        const val LOG_TAG = "Mydroid"
        private const val TAG = "MydroidNotif"

        /** The last Spotify check line (booleans and fixed labels only), or "none yet". Read by the debug broadcast. */
        @Volatile var last: String = "spotify-mediaid none yet"
            private set

        @Suppress("DEPRECATION")
        fun tokenOf(n: Notification): MediaSession.Token? = try {
            val ex = n.extras ?: return null
            if (Build.VERSION.SDK_INT >= 33) ex.getParcelable(Notification.EXTRA_MEDIA_SESSION, MediaSession.Token::class.java)
            else ex.getParcelable(Notification.EXTRA_MEDIA_SESSION)
        } catch (e: Exception) {
            null
        }
    }

    private fun controllerOf(n: Notification): MediaController? = tokenOf(n)?.let { runCatching { MediaController(ctx, it) }.getOrNull() }

    /** Title, artist, album and a forwardable id from the notification's session token, or null when there's nothing to say. */
    fun metaOf(n: Notification): Meta? {
        val md = controllerOf(n)?.metadata ?: return null
        val title = (md.getString(MediaMetadata.METADATA_KEY_TITLE) ?: md.getString(MediaMetadata.METADATA_KEY_DISPLAY_TITLE)).orEmpty()
        val artist = (md.getString(MediaMetadata.METADATA_KEY_ARTIST) ?: md.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST)
            ?: md.getString(MediaMetadata.METADATA_KEY_DISPLAY_SUBTITLE)).orEmpty()
        if (title.isBlank() && artist.isBlank()) return null
        val id = MediaIds.pick(md.getString(MediaMetadata.METADATA_KEY_MEDIA_ID), md.getString(MediaMetadata.METADATA_KEY_MEDIA_URI)).id
        return Meta(title, artist, md.getString(MediaMetadata.METADATA_KEY_ALBUM)?.takeIf { it.isNotBlank() }, id)
    }
}

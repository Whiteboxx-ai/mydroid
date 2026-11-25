package com.mydroid.android.media

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSession
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Base64
import android.util.Log
import com.mydroid.android.notif.MydroidNotificationListener
import com.mydroid.protocol.MediaAction
import com.mydroid.protocol.MediaIds
import com.mydroid.protocol.MediaSnapshot
import com.mydroid.protocol.MediaTracker
import com.mydroid.protocol.Message
import kotlinx.serialization.json.put
import java.io.ByteArrayOutputStream

/**
 * Now playing (PROTOCOL.md 7.3). Watches active media sessions through the notification listener's access,
 * sends `media.state` only when something worth showing changed, and executes `media.cmd`.
 * Everything runs on the main thread; the heavy bit (art encoding) only happens when the track changes.
 */
class MediaBridge(private val ctx: Context, private val send: (Message) -> Boolean) {
    private val main = Handler(Looper.getMainLooper())
    private val msm = ctx.getSystemService(MediaSessionManager::class.java)
    private val component = ComponentName(ctx, MydroidNotificationListener::class.java)
    private val tracker = MediaTracker()
    private var enabled = false
    private var listening = false
    private val watched = LinkedHashMap<MediaSession.Token, Pair<MediaController, MediaController.Callback>>()
    /** Debug builds only: also watch our own sessions, so a synthetic one can be tested without touching the user's players. */
    @Volatile var allowOwn = false

    private val sessionsListener = MediaSessionManager.OnActiveSessionsChangedListener { list -> sync(list.orEmpty()) }
    private val evaluateRunnable = Runnable { evaluate() }
    private val expirePausedRunnable = Runnable { evaluate() }

    /** On when settings.media, the Mac is connected and notification access is granted. */
    fun setEnabled(on: Boolean) {
        main.post {
            if (on == enabled) { if (on && !listening) attach(); return@post }
            enabled = on
            if (on) attach() else {
                detach()
                publishInactive()
            }
        }
    }

    fun refresh() = main.post { if (enabled) { detach(); attach() } }

    /** New TCP session: the Mac knows nothing, so send the current state again. */
    fun resend() = main.post { tracker.reset(); if (enabled) evaluate() }

    private fun attach() {
        try {
            msm.addOnActiveSessionsChangedListener(sessionsListener, component, main)
            listening = true
            sync(msm.getActiveSessions(component))
        } catch (e: SecurityException) {
            detach()
            publishInactive()
            Log.i(TAG, "no notification access yet; media waits")
        }
    }

    private fun detach() {
        runCatching { msm.removeOnActiveSessionsChangedListener(sessionsListener) }
        listening = false
        watched.values.forEach { (c, cb) -> runCatching { c.unregisterCallback(cb) } }
        watched.clear()
        main.removeCallbacks(evaluateRunnable)
        main.removeCallbacks(expirePausedRunnable)
        tracker.reset()
    }

    private fun sync(list: List<MediaController>) {
        val live = list.filter { (allowOwn || it.packageName != ctx.packageName) }
        val tokens = live.map { it.sessionToken }.toSet()
        watched.keys.filter { it !in tokens }.forEach { t -> watched.remove(t)?.let { (c, cb) -> runCatching { c.unregisterCallback(cb) } } }
        for (c in live) {
            if (c.sessionToken in watched) continue
            val cb = object : MediaController.Callback() {
                override fun onPlaybackStateChanged(state: PlaybackState?) = scheduleEvaluate()
                override fun onMetadataChanged(metadata: MediaMetadata?) = scheduleEvaluate()
                override fun onSessionDestroyed() {
                    if (watched[c.sessionToken]?.second === this) watched.remove(c.sessionToken)
                    scheduleEvaluate()
                }
            }
            c.registerCallback(cb, main)
            watched[c.sessionToken] = c to cb
        }
        // Keep the system's priority order for ties.
        scheduleEvaluate()
    }

    private fun scheduleEvaluate() {
        main.removeCallbacks(evaluateRunnable)
        main.postDelayed(evaluateRunnable, 250) // metadata and playback state usually arrive back to back
    }

    private fun isPlaying(c: MediaController) = c.playbackState?.state.let { it == PlaybackState.STATE_PLAYING || it == PlaybackState.STATE_BUFFERING }

    private fun pauseRemaining(state: PlaybackState?, now: Long): Long {
        if (state?.state != PlaybackState.STATE_PAUSED) return 0
        val updateTime = state.lastPositionUpdateTime
        if (updateTime <= 0 || updateTime > now) return 0
        return PAUSED_WINDOW_MS - (now - updateTime)
    }

    private fun best(now: Long): MediaController? {
        val ordered = watched.values.map { it.first }
        return ordered.firstOrNull { isPlaying(it) && it.metadata != null }
            ?: ordered.firstOrNull { pauseRemaining(it.playbackState, now) > 0 && it.metadata != null }
    }

    private fun artOf(md: MediaMetadata): Bitmap? =
        md.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART) ?: md.getBitmap(MediaMetadata.METADATA_KEY_ART) ?: md.getBitmap(MediaMetadata.METADATA_KEY_DISPLAY_ICON)

    private fun evaluate() {
        if (!enabled) return
        val nowElapsed = SystemClock.elapsedRealtime()
        val c = best(nowElapsed)
        val md = c?.metadata
        val st = c?.playbackState
        main.removeCallbacks(expirePausedRunnable)
        val remaining = pauseRemaining(st, nowElapsed)
        if (remaining > 0) main.postDelayed(expirePausedRunnable, remaining)
        val snap = if (c == null || md == null || st == null) null else {
            val now = System.currentTimeMillis()
            val playing = isPlaying(c)
            var pos = st.position.coerceAtLeast(0)
            if (playing && st.state == PlaybackState.STATE_PLAYING) pos += ((nowElapsed - st.lastPositionUpdateTime) * st.playbackSpeed).toLong().coerceAtLeast(0)
            val dur = md.getLong(MediaMetadata.METADATA_KEY_DURATION).coerceAtLeast(0)
            if (dur > 0) pos = pos.coerceAtMost(dur)
            MediaSnapshot(
                pkg = c.packageName,
                title = md.getString(MediaMetadata.METADATA_KEY_TITLE) ?: md.getString(MediaMetadata.METADATA_KEY_DISPLAY_TITLE) ?: "",
                artist = md.getString(MediaMetadata.METADATA_KEY_ARTIST) ?: md.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST) ?: md.getString(MediaMetadata.METADATA_KEY_DISPLAY_SUBTITLE) ?: "",
                album = md.getString(MediaMetadata.METADATA_KEY_ALBUM) ?: "",
                playing = playing, position = pos, duration = dur, ts = now,
                canSeek = st.actions and PlaybackState.ACTION_SEEK_TO != 0L,
                canNext = st.actions and PlaybackState.ACTION_SKIP_TO_NEXT != 0L,
                canPrev = st.actions and PlaybackState.ACTION_SKIP_TO_PREVIOUS != 0L,
                hasArt = artOf(md) != null,
                // PROTOCOL.md 15: only spotify:track / spotify:episode / http(s). Part of the track key, so a new track sends it.
                mediaId = MediaIds.pick(md.getString(MediaMetadata.METADATA_KEY_MEDIA_ID), md.getString(MediaMetadata.METADATA_KEY_MEDIA_URI)).id,
            )
        }
        val d = tracker.decide(snap)
        if (!d.send) return
        if (snap == null || c == null) {
            publishInactive()
            return
        }
        val art = if (d.withArt) c.metadata?.let(::artOf)?.let(::encodeArt) else null
        val msg = snap.toMessage(appLabel(snap.pkg), art)
        if (!send(msg)) {
            tracker.reset()
            return
        }
        Log.i(TAG, "media.state sent active=true pkg=${snap.pkg} playing=${snap.playing} pos=${snap.position} dur=${snap.duration} art=${art?.length ?: 0}B titleLen=${snap.title.length} id=${snap.mediaId != null}")
    }

    private fun publishInactive() {
        if (!send(Message.of("media.state") { put("active", false) })) tracker.reset()
    }

    private fun appLabel(pkg: String): String = try {
        ctx.packageManager.getApplicationLabel(ctx.packageManager.getApplicationInfo(pkg, 0)).toString()
    } catch (e: PackageManager.NameNotFoundException) {
        pkg
    }

    /** JPEG, longest side <= 256 px. */
    private fun encodeArt(src: Bitmap): String? = try {
        val scale = 256f / maxOf(src.width, src.height)
        val bmp = if (scale < 1f) Bitmap.createScaledBitmap(src, (src.width * scale).toInt().coerceAtLeast(1), (src.height * scale).toInt().coerceAtLeast(1), true) else src
        val flat = if (bmp.hasAlpha()) bmp.copy(Bitmap.Config.ARGB_8888, false) else bmp
        val out = ByteArrayOutputStream()
        flat.compress(Bitmap.CompressFormat.JPEG, 78, out)
        Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
    } catch (e: Exception) {
        null
    }

    /** `media.cmd` from the Mac. */
    fun command(action: String, position: Long?) {
        main.post {
            if (!enabled) return@post
            val c = best(SystemClock.elapsedRealtime()) ?: return@post
            val t = c.transportControls
            Log.i(TAG, "media.cmd $action pkg=${c.packageName}")
            when (MediaAction.parse(action, isPlaying(c))) {
                MediaAction.Play -> t.play()
                MediaAction.Pause -> t.pause()
                MediaAction.Next -> t.skipToNext()
                MediaAction.Prev -> t.skipToPrevious()
                MediaAction.Seek -> if (position != null) t.seekTo(position.coerceAtLeast(0))
                null -> {}
            }
        }
    }

    private companion object {
        const val TAG = "MydroidMedia"
        const val PAUSED_WINDOW_MS = 60_000L
    }
}

package com.mydroid.android.notif

import android.app.ActivityOptions
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import androidx.core.app.NotificationCompat
import com.mydroid.android.Channels
import com.mydroid.android.Perms
import com.mydroid.android.R
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * `notif.open` (PROTOCOL.md 13.2): send the notification's own `contentIntent` (what tapping it would do).
 *
 * A companion-device association lets Mydroid start activities from the background; on Android 14+ the send also
 * asks for `MODE_BACKGROUND_ACTIVITY_START_ALLOWED`. When the start is refused (cancelled PendingIntent, or the
 * system reports the start aborted) a high-priority "Tap to open in <App>" notification carries the same
 * PendingIntent, removed after 2 minutes. A notification that's already gone gets its app launched instead.
 * Logs outcomes only, never what the notification said. Runs on the caller's worker thread plus its own handler thread.
 */
class NotifOpener(
    private val ctx: Context,
    private val worker: ScheduledExecutorService,
    private val appLabel: (String) -> String,
) {
    class Result(val ok: Boolean, val error: String?, val note: String?)

    private val handlerThread by lazy { HandlerThread("mydroid-notif-open").apply { isDaemon = true; start() } }
    private val handler by lazy { Handler(handlerThread.looper) }

    /**
     * [pi] is the notification's contentIntent, or null when there's no live notification (or it has none): then the
     * app named by [pkg] is launched. [reply] is called exactly once.
     */
    fun open(key: String, pkg: String?, pi: PendingIntent?, reply: (Result) -> Unit) {
        var intent = pi
        var launched = false
        if (intent == null) {
            val launch = pkg?.let { ctx.packageManager.getLaunchIntentForPackage(it) }
            if (pkg == null || launch == null) {
                Log.i(TAG, "notif.open nothing to open found=${pi != null}")
                return reply(Result(false, "That notification is gone", null))
            }
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
            intent = PendingIntent.getActivity(ctx, pkg.hashCode(), launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            launched = true
        }
        fire(key, pkg, intent!!, launched, reply)
    }

    private fun fire(key: String, pkg: String?, pi: PendingIntent, launched: Boolean, reply: (Result) -> Unit) {
        val done = AtomicBoolean(false)
        val via = if (launched) "launch" else "contentIntent"
        fun finish(ok: Boolean, why: String, code: Int?) {
            if (!done.compareAndSet(false, true)) return
            Log.i(TAG, "notif.open ok=$ok via=$via why=$why${code?.let { " code=$it" } ?: ""} sdk=${Build.VERSION.SDK_INT}")
            if (ok) return reply(Result(true, null, if (launched) "launched app" else null))
            postFallback(key, pkg, pi)
            reply(Result(false, "Your phone needs a tap to open it. Check its notifications.", null))
        }
        val isActivity = Build.VERSION.SDK_INT < 31 || pi.isActivity
        val onFinished = PendingIntent.OnFinished { _, _, resultCode, _, _ ->
            // For an activity the code is the start result: 0..3 started or was brought forward, 102 aborted (blocked), negatives failed.
            if (!isActivity || resultCode in 0..3) finish(true, "started", resultCode) else finish(false, "refused", resultCode)
        }
        try {
            pi.send(ctx, 0, null, onFinished, handler, null, backgroundStartOptions())
            // No verdict (a broadcast or service, or an OS that doesn't report): the send itself went through.
            worker.schedule({ finish(true, "sent", null) }, VERDICT_WAIT_MS, TimeUnit.MILLISECONDS)
        } catch (e: PendingIntent.CanceledException) {
            finish(false, "canceled", null)
        } catch (e: Exception) {
            finish(false, e.javaClass.simpleName, null)
        }
    }

    private fun backgroundStartOptions(): Bundle? =
        if (Build.VERSION.SDK_INT >= 34) {
            ActivityOptions.makeBasic()
                .setPendingIntentBackgroundActivityStartMode(ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED)
                .toBundle()
        } else null

    private fun postFallback(key: String, pkg: String?, pi: PendingIntent) {
        if (!Perms.canPostNotifications(ctx)) { Log.i(TAG, "notif.open fallback skipped (no notification permission)"); return }
        val label = pkg?.let(appLabel) ?: "the app"
        val id = ID_BASE + (key.hashCode() and 0x3f)
        val n = NotificationCompat.Builder(ctx, Channels.OPEN)
            .setSmallIcon(R.drawable.ic_stat_mydroid)
            .setContentTitle("Tap to open in $label")
            .setContentText("From your Mac")
            .setContentIntent(pi).setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE).setPriority(NotificationCompat.PRIORITY_HIGH)
            .setTimeoutAfter(CLEANUP_MS)
            .build()
        val nm = ctx.getSystemService(NotificationManager::class.java)
        runCatching { nm.notify(ID_BASE.toString(), id, n) }
        worker.schedule({ runCatching { nm.cancel(ID_BASE.toString(), id) } }, CLEANUP_MS, TimeUnit.MILLISECONDS)
        Log.i(TAG, "notif.open fallback notification posted")
    }

    private companion object {
        const val TAG = "MydroidNotif"
        const val ID_BASE = 4600
        const val CLEANUP_MS = 2 * 60_000L
        const val VERDICT_WAIT_MS = 4_000L
    }
}

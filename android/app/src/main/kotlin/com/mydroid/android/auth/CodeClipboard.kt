package com.mydroid.android.auth

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle

/**
 * Copies a code marked sensitive (so Android 13+ hides it in the clipboard preview and keyboards skip it) and wipes it
 * [CLEAR_AFTER_MS] later, unless something else was copied in the meantime (then the clipboard is no longer ours to clear).
 * Needs the process alive for the timer; the connection service keeps it so while paired. Never logs the code.
 */
object CodeClipboard {
    const val CLEAR_AFTER_MS = 30_000L
    private const val SENSITIVE = "android.content.extra.IS_SENSITIVE" // ClipDescription.EXTRA_IS_SENSITIVE, API 33; older keyboards read the literal

    private val main = Handler(Looper.getMainLooper())
    private var clear: Runnable? = null
    private var listener: ClipboardManager.OnPrimaryClipChangedListener? = null
    @Volatile private var expectingOurs = false
    @Volatile private var superseded = false

    fun copy(ctx: Context, code: String) {
        val cm = ctx.applicationContext.getSystemService(ClipboardManager::class.java)
        main.post {
            cancel(cm)
            superseded = false
            expectingOurs = true
            val l = ClipboardManager.OnPrimaryClipChangedListener {
                if (expectingOurs) expectingOurs = false else superseded = true
            }
            listener = l
            cm.addPrimaryClipChangedListener(l)
            val clip = ClipData.newPlainText("code", code).apply {
                description.extras = PersistableBundle().apply { putBoolean(SENSITIVE, true) }
            }
            cm.setPrimaryClip(clip)
            val r = Runnable {
                if (!superseded) runCatching { cm.clearPrimaryClip() }
                cancel(cm)
            }
            clear = r
            main.postDelayed(r, CLEAR_AFTER_MS)
        }
    }

    private fun cancel(cm: ClipboardManager) {
        clear?.let { main.removeCallbacks(it) }; clear = null
        listener?.let { runCatching { cm.removePrimaryClipChangedListener(it) } }; listener = null
        expectingOurs = false
    }
}

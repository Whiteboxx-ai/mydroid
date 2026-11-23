package com.mydroid.android.clip

import android.accessibilityservice.AccessibilityService
import android.content.ClipDescription
import android.content.ClipboardManager
import android.graphics.PixelFormat
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import com.mydroid.android.BuildConfig
import com.mydroid.android.manager

/**
 * Phone -> Mac clipboard without a button press. OPT-IN ("Instant copy (advanced)", off by default): some banking apps
 * warn while an accessibility service is on, so this does nothing unless the user opted in (`wanted`, set by ConnectionManager).
 *
 * Android 10+ lets only the focused app (or the default keyboard) read the clipboard. An
 * accessibility service may add a TYPE_ACCESSIBILITY_OVERLAY window without any overlay permission, and
 * a focusable window makes our uid "the focused app" for a few milliseconds. So:
 *
 *  1. A copy signal arrives: a click on a "Copy"/"Copy link"/... control, a "Copied" toast, or the
 *     Android 13+ system clipboard overlay.
 *  2. Wait ~250 ms (the clipboard is written after the click), then add a 1x1 transparent window that is
 *     focusable but FLAG_ALT_FOCUSABLE_IM, so it never becomes the input-method target and a keyboard
 *     the user has up stays up.
 *  3. When that window gains focus, read primaryClip, remove the window in the same frame.
 *  4. Hand the text to the ConnectionManager, which drops it unless clipboard sharing is on, the Mac is
 *     connected, and the text differs from what was last synced (this also stops echoes of Mac writes).
 *
 * No canRetrieveWindowContent: we never look at screen content. Logs only lengths and signal kinds.
 */
class ClipAccessibilityService : AccessibilityService() {
    private val main = Handler(Looper.getMainLooper())
    private var probe: View? = null
    private var lastReadAt = 0L
    private var lastStamp = 0L
    private var pendingKind = ""
    private val readRunnable = Runnable { startRead() }
    private val timeoutRunnable = Runnable { probe?.let { Log.i(TAG, "overlay never got focus"); removeOverlay() } }

    override fun onServiceConnected() {
        instance = this
        applyActive()
        manager().refreshFeatures()
        Log.i(TAG, "service connected active=$wanted")
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        instance = null
        main.removeCallbacks(readRunnable)
        removeOverlay()
        manager().refreshFeatures()
        return super.onUnbind(intent)
    }

    override fun onInterrupt() {}

    override fun onAccessibilityEvent(e: AccessibilityEvent) {
        // Opt-in only: `wanted` is true only while the user turned on "Instant copy", the feature is on and the Mac is here.
        // If the service is enabled in Settings without that (a leftover), ignore everything.
        if (!wanted) return
        val kind = classify(e) ?: return
        // A weak signal must not downgrade a strong one waiting out the settle delay.
        if (!(kind == "systemui" && pendingKind != "" && pendingKind != "systemui")) pendingKind = kind
        main.removeCallbacks(readRunnable)
        main.postDelayed(readRunnable, SETTLE_MS)
    }

    private fun classify(e: AccessibilityEvent): String? {
        when (e.eventType) {
            AccessibilityEvent.TYPE_VIEW_CLICKED, AccessibilityEvent.TYPE_VIEW_LONG_CLICKED -> {
                if (e.text.any { isCopyLabel(it) } || isCopyLabel(e.contentDescription)) return "click"
            }
            AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED -> {
                // Real notifications also arrive here; toasts have a Toast class name.
                if (e.className?.contains("Toast") == true && e.text.any { COPIED.containsMatchIn(it ?: "") }) return "toast"
            }
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> {
                if (e.packageName == "com.android.systemui") {
                    val cn = e.className?.toString().orEmpty()
                    if (BuildConfig.DEBUG) Log.d(TAG, "systemui window class=$cn texts=${e.text.map { it?.length }} copiedWord=${e.text.any { it != null && COPIED.containsMatchIn(it) }} descLen=${e.contentDescription?.length ?: -1}")
                    if (cn.contains("clipboard", true) || e.text.any { it?.contains("clipboard", true) == true || (it != null && COPIED.containsMatchIn(it)) } ||
                        e.contentDescription?.contains("clipboard", true) == true
                    ) return "overlay"
                    // Generic systemui window (the Android 13+ clipboard preview reports a bare FrameLayout): only worth a
                    // look when the clip description proves the clipboard changed; see startRead().
                    return "systemui"
                }
            }
        }
        return null
    }

    private fun isCopyLabel(t: CharSequence?): Boolean {
        if (t == null || t.length > MAX_LABEL) return false
        return COPY_LABEL.containsMatchIn(t)
    }

    private fun startRead() {
        if (!wanted || probe != null) return
        val now = System.currentTimeMillis()
        if (now - lastReadAt < COOLDOWN_MS) return
        val cm = getSystemService(ClipboardManager::class.java)
        // Description (no content) is readable without focus on some builds; use its timestamp to skip a clip we already handled.
        val d = runCatching { cm.primaryClipDescription }.getOrNull()
        if (BuildConfig.DEBUG) Log.d(TAG, "startRead kind=$pendingKind descReadable=${d != null}")
        if (d != null && d.timestamp != 0L && d.timestamp <= lastStamp) {
            Log.i(TAG, "skip: clip unchanged kind=$pendingKind")
            return
        }
        // The weak systemui signal never opens a window unless the description is readable and newer.
        if (pendingKind == "systemui" && (d == null || d.timestamp == 0L)) return
        lastReadAt = now
        addOverlay()
    }

    private fun addOverlay() {
        val wm = getSystemService(WindowManager::class.java)
        val v = object : View(this) {
            override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
                super.onWindowFocusChanged(hasWindowFocus)
                if (hasWindowFocus && this@ClipAccessibilityService.probe === this) readAndRemove()
            }
        }
        val lp = WindowManager.LayoutParams(
            1, 1, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            // Focusable (no FLAG_NOT_FOCUSABLE) so we count as the focused app, but ALT_FOCUSABLE_IM keeps the
            // IME from moving to us. Not touchable: it never swallows a tap.
            WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSPARENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            title = "mydroid-clip"
            softInputMode = WindowManager.LayoutParams.SOFT_INPUT_STATE_UNCHANGED or WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING
        }
        probe = v
        try {
            wm.addView(v, lp)
            main.postDelayed(timeoutRunnable, FOCUS_TIMEOUT_MS)
        } catch (e: Exception) {
            Log.w(TAG, "addView failed: ${e.javaClass.simpleName}")
            probe = null
        }
    }

    private fun readAndRemove() {
        var text: String? = null
        var sensitive = false
        var kindOfClip = "none"
        try {
            val cm = getSystemService(ClipboardManager::class.java)
            val clip = cm.primaryClip
            val d = clip?.description
            if (d != null) {
                lastStamp = maxOf(lastStamp, d.timestamp)
                sensitive = Clipboard.isSensitive(d)
                kindOfClip = if (d.hasMimeType("text/*")) "text" else "other"
                if (!sensitive && d.hasMimeType("text/*") && clip.itemCount > 0) {
                    text = clip.getItemAt(0).coerceToText(this)?.toString()?.takeIf { it.isNotEmpty() }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "clipboard read failed: ${e.javaClass.simpleName}")
        }
        // Removing the view from inside its own focus callback crashes ViewRootImpl; post to the very next loop turn.
        main.post { removeOverlay() }
        val kind = pendingKind
        pendingKind = ""
        Log.i(TAG, "read kind=$kind clip=$kindOfClip sensitive=$sensitive len=${text?.length ?: 0}")
        text?.let { manager().onClipboardObserved(it, kind) }
    }

    private fun removeOverlay() {
        main.removeCallbacks(timeoutRunnable)
        val v = probe ?: return
        probe = null
        runCatching { getSystemService(WindowManager::class.java).removeViewImmediate(v) }
    }

    private fun applyActive() {
        val info = serviceInfo ?: return
        val want = if (wanted) EVENT_TYPES else 0
        if (info.eventTypes != want) {
            info.eventTypes = want
            serviceInfo = info
        }
    }

    companion object {
        private const val TAG = "MydroidClip"
        private const val SETTLE_MS = 250L
        private const val COOLDOWN_MS = 1200L
        private const val FOCUS_TIMEOUT_MS = 600L
        private const val MAX_LABEL = 28
        private const val EVENT_TYPES = AccessibilityEvent.TYPE_VIEW_CLICKED or AccessibilityEvent.TYPE_VIEW_LONG_CLICKED or
            AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED or AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED

        // "Copy", "Copy link", "Copy text", "Copy code", "Copy link address", "Copied", "Link copied".
        private val COPY_LABEL = Regex("(?i)^\\s*(copy|copied)\\b|\\b(copied|copy (link|text|code|url|message|address|to clipboard))\\b")
        private val COPIED = Regex("(?i)\\bcopied\\b")

        @Volatile private var instance: ClipAccessibilityService? = null
        /** True while clipboard sharing is on and the Mac is connected; otherwise the service subscribes to no events. */
        @Volatile private var wanted = false

        fun setActive(active: Boolean) {
            if (wanted == active) return
            wanted = active
            instance?.let { s -> s.main.post { s.applyActive() } }
        }
    }
}

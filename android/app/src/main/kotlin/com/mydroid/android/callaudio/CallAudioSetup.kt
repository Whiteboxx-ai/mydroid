package com.mydroid.android.callaudio

import android.Manifest
import android.content.Context
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.Settings as AndroidSettings
import android.util.Log
import com.mydroid.android.Perms
import com.mydroid.android.data.Settings
import java.io.File

enum class CallAudioState(val wire: String) { On("on"), NeedsSetup("needs_setup"), Off("off") }

/** What `feature.status` and the Home row say about "Hear calls on your Mac" (PROTOCOL.md 8.2). */
data class CallAudioStatus(
    val state: CallAudioState = CallAudioState.Off,
    /** Settings.Global.DEVELOPMENT_SETTINGS_ENABLED */
    val devOptions: Boolean = false,
    /** Settings.Global "adb_wifi_enabled" (Wireless debugging) */
    val adbWifi: Boolean = false,
)

/**
 * Phone side of the optional Mac call-audio setup. The heavy lifting (pairing, adb) happens on the Mac; here we only
 * (1) report where setup stands, (2) keep Wireless debugging switched on while the user wants call audio and the Mac has been
 * granted WRITE_SECURE_SETTINGS, and (3) prove to the Mac, over the shell, that it paired the right phone.
 * We never write a setting unless call audio is on *and* the permission is granted.
 */
object CallAudioSetup {
    private const val TAG = "MydroidCallAudio"
    const val ADB_WIFI = "adb_wifi_enabled"
    private const val VERIFY_FILE = "adb-verify"
    private const val VERIFY_TTL_MS = 2 * 60_000L
    private var lastWrite = -10_000L
    private val NONCE_OK = Regex("[A-Za-z0-9+/=_.-]{1,128}")

    fun canWriteSecure(c: Context) = Perms.granted(c, Manifest.permission.WRITE_SECURE_SETTINGS)

    fun devOptions(c: Context): Boolean = try {
        AndroidSettings.Global.getInt(c.contentResolver, AndroidSettings.Global.DEVELOPMENT_SETTINGS_ENABLED, 0) == 1
    } catch (e: Exception) { false }

    fun adbWifi(c: Context): Boolean = try {
        AndroidSettings.Global.getInt(c.contentResolver, ADB_WIFI, 0) == 1
    } catch (e: Exception) { false }

    fun status(c: Context, s: Settings): CallAudioStatus = CallAudioStatus(
        state = when {
            !s.callAudio -> CallAudioState.Off
            canWriteSecure(c) -> CallAudioState.On
            else -> CallAudioState.NeedsSetup
        },
        devOptions = devOptions(c),
        adbWifi = adbWifi(c),
    )

    /**
     * Keep-alive (8.2.5): Android turns Wireless debugging off when the Wi-Fi network changes. While call audio is on and
     * we hold WRITE_SECURE_SETTINGS, switch it back on. Called on boot, on Wi-Fi connect and when the setting flips.
     * Returns true if it wrote. Touches nothing otherwise.
     */
    fun keepAlive(c: Context, s: Settings): Boolean {
        if (!s.callAudio || !canWriteSecure(c) || adbWifi(c)) return false
        // If something keeps switching it off again, don't fight it in a tight loop (our own write wakes the observer).
        val now = android.os.SystemClock.elapsedRealtime()
        synchronized(this) { if (now - lastWrite < 5_000) return false; lastWrite = now }
        return try {
            val ok = AndroidSettings.Global.putInt(c.contentResolver, ADB_WIFI, 1)
            Log.i(TAG, "keep-alive: adb_wifi_enabled=1 written=$ok")
            ok
        } catch (e: SecurityException) {
            Log.w(TAG, "keep-alive refused: permission went away")
            false
        } catch (e: Exception) {
            Log.w(TAG, "keep-alive failed: ${e.javaClass.simpleName}")
            false
        }
    }

    // ------------------------------------------------------------------ adb.verify

    private val handler = Handler(Looper.getMainLooper())

    private fun verifyFile(c: Context): File? = c.getExternalFilesDir(null)?.let { File(it, VERIFY_FILE) }

    /**
     * `adb.verify {nonce}`: the Mac reads this file with `adb shell cat` to prove the adb connection reaches the phone it
     * paired over Mydroid. Shell can read Android/data, so no world-readable mode. Deleted after 2 minutes.
     */
    fun writeVerify(c: Context, nonce: String?): Boolean {
        if (nonce == null || !NONCE_OK.matches(nonce)) { Log.w(TAG, "adb.verify refused (bad nonce)"); return false }
        val f = verifyFile(c) ?: run { Log.w(TAG, "adb.verify: no external files dir"); return false }
        return try {
            f.writeText(nonce)
            handler.removeCallbacksAndMessages(VERIFY_FILE)
            handler.postAtTime({ f.delete() }, VERIFY_FILE, android.os.SystemClock.uptimeMillis() + VERIFY_TTL_MS)
            Log.i(TAG, "adb.verify written len=${nonce.length}")
            true
        } catch (e: Exception) {
            Log.w(TAG, "adb.verify failed: ${e.javaClass.simpleName}")
            false
        }
    }

    /** A verify file outlives the process if we were killed inside the 2-minute window. Drop a stale one at startup. */
    fun deleteStaleVerify(c: Context) {
        runCatching {
            val f = verifyFile(c) ?: return
            if (f.exists() && System.currentTimeMillis() - f.lastModified() > VERIFY_TTL_MS) f.delete()
        }
    }
}

/**
 * Watches the two global settings the Mac setup flow cares about (Developer options, Wireless debugging) while a Mac is
 * connected and wants call audio, so `feature.status` follows along and the keep-alive re-arms the moment Android drops it.
 */
class CallAudioWatcher(private val c: Context, private val onChange: () -> Unit) {
    private val handler = Handler(Looper.getMainLooper())
    private var observer: ContentObserver? = null

    @Synchronized
    fun setWatching(on: Boolean) {
        if (on == (observer != null)) return
        if (on) {
            val o = object : ContentObserver(handler) { override fun onChange(selfChange: Boolean) = onChange() }
            val r = c.contentResolver
            runCatching {
                r.registerContentObserver(AndroidSettings.Global.getUriFor(CallAudioSetup.ADB_WIFI), false, o)
                r.registerContentObserver(AndroidSettings.Global.getUriFor(AndroidSettings.Global.DEVELOPMENT_SETTINGS_ENABLED), false, o)
            }
            observer = o
        } else {
            observer?.let { runCatching { c.contentResolver.unregisterContentObserver(it) } }
            observer = null
        }
    }
}

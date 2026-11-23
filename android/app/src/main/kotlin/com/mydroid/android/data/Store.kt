package com.mydroid.android.data

import android.content.Context
import com.mydroid.protocol.Credentials
import com.mydroid.protocol.HostPort
import java.util.UUID

/** Which features the Mac asked for. */
data class Settings(
    val notifications: Boolean = false,
    val photos: Boolean = false,
    val calls: Boolean = false,
    val clipboard: Boolean = false,
    // v1.2 (PROTOCOL.md 7.2)
    val mutedApps: Set<String> = emptySet(),
    val screenshots: Boolean = true,
    val pauseBelowBattery: Int? = null,
    val smsHistory: Boolean = false,
    val media: Boolean = false,
    /** Optional "Hear calls on your Mac" (PROTOCOL.md 8). */
    val callAudio: Boolean = false,
    /** Walk-away lock (PROTOCOL.md 12): the phone advertises BLE while connected so the Mac can tell when it leaves. */
    val walkAway: Boolean = false,
) {
    val any get() = notifications || photos || calls || clipboard || media || smsHistory
}

/** Pairing identity and small prefs. The LTK is only ever stored wrapped by the Android Keystore. */
class Store(context: Context) {
    private val p = context.applicationContext.getSharedPreferences("mydroid", Context.MODE_PRIVATE)

    val phoneId: String
        get() = p.getString("phoneId", null) ?: UUID.randomUUID().toString().also { p.edit().putString("phoneId", it).apply() }

    val macId: String? get() = p.getString("macId", null)
    var macName: String
        get() = p.getString("macName", null) ?: "your Mac"
        set(v) = p.edit().putString("macName", v).apply()
    val addresses: List<HostPort>
        get() = (p.getString("addresses", "") ?: "").split(',').mapNotNull { HostPort.parse(it) }
    var lastGood: HostPort?
        get() = p.getString("lastGood", null)?.let { HostPort.parse(it) }
        set(v) = p.edit().putString("lastGood", v?.toString()).apply()
    var pairedAt: Long
        get() = p.getLong("pairedAt", 0)
        set(v) = p.edit().putLong("pairedAt", v).apply()
    var lastSeen: Long
        get() = p.getLong("lastSeen", 0)
        set(v) = p.edit().putLong("lastSeen", v).apply()
    /** DATE_ADDED (seconds) high-water mark of photos already considered for the queue. */
    var photoScanMark: Long
        get() = p.getLong("photoScanMark", 0)
        set(v) = p.edit().putLong("photoScanMark", v).apply()
    /** The user went through (or skipped) the permission screen after pairing. */
    var setupDone: Boolean
        get() = p.getBoolean("setupDone", false)
        set(v) = p.edit().putBoolean("setupDone", v).apply()
    /** When the user last opened the OEM auto-start screen. A phone setting, so it survives re-pairing. */
    var oemOpenedAt: Long
        get() = p.getLong("oemOpenedAt", 0)
        set(v) = p.edit().putLong("oemOpenedAt", v).apply()

    /** The user opted in to "Instant copy (advanced)" (accessibility service). Off by default; a phone setting, so it survives re-pairing. */
    var instantCopy: Boolean
        get() = p.getBoolean("instantCopy", false)
        set(v) = p.edit().putBoolean("instantCopy", v).apply()

    /** The BLE presence companion association (CompanionDeviceManager id), or -1. Cleared on unpair. */
    var assocId: Int
        get() = p.getInt("assocId", -1)
        set(v) = p.edit().putInt("assocId", v).apply()

    var settings: Settings
        get() = Settings(
            p.getBoolean("s_notifications", false), p.getBoolean("s_photos", false),
            p.getBoolean("s_calls", false), p.getBoolean("s_clipboard", false),
            mutedApps = (p.getString("s_muted", "") ?: "").split('\n').filter { it.isNotBlank() }.toSet(),
            screenshots = p.getBoolean("s_screenshots", true),
            pauseBelowBattery = p.getInt("s_pauseBelow", -1).takeIf { it >= 0 },
            smsHistory = p.getBoolean("s_smsHistory", false), media = p.getBoolean("s_media", false),
            callAudio = p.getBoolean("s_callAudio", false),
            walkAway = p.getBoolean("s_walkAway", false),
        )
        set(v) = p.edit().putBoolean("s_notifications", v.notifications).putBoolean("s_photos", v.photos)
            .putBoolean("s_calls", v.calls).putBoolean("s_clipboard", v.clipboard)
            .putString("s_muted", v.mutedApps.joinToString("\n")).putBoolean("s_screenshots", v.screenshots)
            .putInt("s_pauseBelow", v.pauseBelowBattery ?: -1).putBoolean("s_smsHistory", v.smsHistory)
            .putBoolean("s_media", v.media).putBoolean("s_callAudio", v.callAudio).putBoolean("s_walkAway", v.walkAway).apply()
    /** Starred Shortcuts (PROTOCOL.md 11), one name per line. They belong to the paired Mac, so unpairing clears them. */
    var favoriteShortcuts: List<String>
        get() = com.mydroid.protocol.Favorites.decode(p.getString("favShortcuts", null))
        set(v) = p.edit().putString("favShortcuts", com.mydroid.protocol.Favorites.encode(v)).apply()
    /** The Mac has asked for call audio at least once; tells "Off" apart from "never set up" on the Home row. */
    var callAudioEver: Boolean
        get() = p.getBoolean("callAudioEver", false)
        set(v) = p.edit().putBoolean("callAudioEver", v).apply()
    val hasSettings: Boolean get() = p.contains("s_notifications")
    /** Mac files (PROTOCOL.md 9): the last `fs.roots` answer, so the Files root keeps its flags while the Mac is away. */
    var fsWritable: Boolean
        get() = p.getBoolean("fsWritable", false)
        set(v) = p.edit().putBoolean("fsWritable", v).apply()
    /** The Mac answered `fs.roots` with an empty list: file sharing is off there, so the Files root is hidden. */
    var fsOff: Boolean
        get() = p.getBoolean("fsOff", false)
        set(v) = p.edit().putBoolean("fsOff", v).apply()

    val isPaired: Boolean get() = macId != null && p.contains("ltk")

    fun credentials(): Credentials? {
        val mac = macId ?: return null
        val ltk = p.getString("ltk", null)?.let { KeystoreCipher.decrypt(it) } ?: return null
        return Credentials(phoneId, mac, ltk)
    }

    fun savePairing(macId: String, macName: String, ltk: ByteArray, addresses: List<HostPort>, lastGood: HostPort?) {
        p.edit()
            .putString("macId", macId).putString("macName", macName)
            .putString("ltk", KeystoreCipher.encrypt(ltk))
            .putString("addresses", addresses.joinToString(",") { it.toString() })
            .putString("lastGood", lastGood?.toString())
            .putLong("pairedAt", System.currentTimeMillis())
            .putLong("lastSeen", System.currentTimeMillis())
            .putLong("photoScanMark", 0)
            .putBoolean("setupDone", false)
            .remove("s_notifications")
            .apply()
    }

    fun clearPairing() {
        p.edit().remove("macId").remove("macName").remove("ltk").remove("addresses").remove("lastGood")
            .remove("pairedAt").remove("lastSeen").remove("setupDone")
            .remove("s_notifications").remove("s_photos").remove("s_calls").remove("s_clipboard")
            .remove("s_muted").remove("s_screenshots").remove("s_pauseBelow").remove("s_smsHistory").remove("s_media").remove("s_callAudio").remove("s_walkAway").remove("favShortcuts").remove("callAudioEver").remove("assocId").remove("fsWritable").remove("fsOff").apply()
        KeystoreCipher.deleteKey()
    }
}

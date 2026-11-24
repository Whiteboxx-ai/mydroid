package com.mydroid.android

import android.Manifest
import android.app.ActivityManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.PowerManager
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.mydroid.android.data.Settings

enum class Feature(val wire: String, val title: String) {
    Notifications("notifications", "Notifications"),
    Photos("photos", "Camera roll"),
    Calls("calls", "Calls"),
    Clipboard("clipboard", "Clipboard"),
    /** SMS history and sending (PROTOCOL.md 7.5). Optional in `feature.status`. */
    Sms("sms", "Text messages"),
}

enum class FeatureState(val wire: String) { On("on"), Off("off"), NeedsPermission("needs_permission") }

/** A point-in-time reading of what Android lets us do. Cheap to compute, safe to recompute on resume. */
data class FeatureReport(
    val states: Map<Feature, FeatureState> = emptyMap(),
    val backgroundRestricted: Boolean = false,
    val batteryOptimizationExempt: Boolean = false,
    val postNotifications: Boolean = true,
    val photosPartial: Boolean = false,
    val callsMissingOptional: Boolean = false,
    /** CALL_PHONE: "Call from your Mac" (PROTOCOL.md 7.8). */
    val dial: Boolean = false,
    /** One-time codes via RECEIVE_SMS (only meaningful while notifications are on). */
    val otp: FeatureState = FeatureState.Off,
    /** Bluetooth presence (PROTOCOL.md 7.1): permission and companion association. */
    val presence: com.mydroid.android.presence.PresenceStatus = com.mydroid.android.presence.PresenceStatus.Unsupported,
    /** Watch-role association held: Android shows Mydroid OTPs it otherwise hides. */
    val codesFromApps: Boolean = false,
    val bluetoothOn: Boolean = true,
    /** "Hear calls on your Mac" (PROTOCOL.md 8.2). */
    val callAudio: com.mydroid.android.callaudio.CallAudioStatus = com.mydroid.android.callaudio.CallAudioStatus(),
    val callAudioEver: Boolean = false,
    /** The user opted in to "Instant copy (advanced)" (the accessibility service). Off by default. */
    val instantCopy: Boolean = false,
    /** Our accessibility service is switched on in Android settings, whether or not the user opted in. */
    val a11yEnabled: Boolean = false,
    /** Walk-away lock (PROTOCOL.md 12): what Android allows for the phone's beacon. Off unless the Mac turned it on. */
    val walkAway: com.mydroid.android.walkaway.WalkAwayStatus = com.mydroid.android.walkaway.WalkAwayStatus.Off,
) {
    fun state(f: Feature) = states[f] ?: FeatureState.Off
    /** `"instant"` only when opted in and the service is really on; otherwise the manual paths ("tap"). */
    val clipboardMode: String get() = if (instantCopy && a11yEnabled) "instant" else "tap"
    /** The service is on in Accessibility settings but the user hasn't opted in: show the hint. */
    val instantStray: Boolean get() = a11yEnabled && !instantCopy
}

object Perms {
    fun photoPermissions(): Array<String> = buildList {
        when {
            Build.VERSION.SDK_INT >= 34 -> {
                add(Manifest.permission.READ_MEDIA_IMAGES)
                add(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
            }
            Build.VERSION.SDK_INT >= 33 -> add(Manifest.permission.READ_MEDIA_IMAGES)
            else -> add(Manifest.permission.READ_EXTERNAL_STORAGE)
        }
        add(Manifest.permission.ACCESS_MEDIA_LOCATION)
    }.toTypedArray()

    val callPermissions = arrayOf(
        Manifest.permission.READ_PHONE_STATE,
        Manifest.permission.READ_CALL_LOG,
        Manifest.permission.ANSWER_PHONE_CALLS,
        Manifest.permission.READ_CONTACTS,
    )

    /** Text from your Mac (PROTOCOL.md 7.5). READ_CONTACTS only adds names and photos. */
    val smsHistoryPermissions = arrayOf(
        Manifest.permission.READ_SMS,
        Manifest.permission.SEND_SMS,
        Manifest.permission.READ_CONTACTS,
    )

    fun granted(c: Context, p: String) = ContextCompat.checkSelfPermission(c, p) == PackageManager.PERMISSION_GRANTED

    /** Full or (Android 14+) partial access to photos. */
    fun hasPhotoAccess(c: Context): Boolean = when {
        Build.VERSION.SDK_INT >= 33 ->
            granted(c, Manifest.permission.READ_MEDIA_IMAGES) ||
                (Build.VERSION.SDK_INT >= 34 && granted(c, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED))
        else -> granted(c, Manifest.permission.READ_EXTERNAL_STORAGE)
    }

    fun hasFullPhotoAccess(c: Context): Boolean =
        if (Build.VERSION.SDK_INT >= 33) granted(c, Manifest.permission.READ_MEDIA_IMAGES) else granted(c, Manifest.permission.READ_EXTERNAL_STORAGE)

    fun canReadOriginals(c: Context) = granted(c, Manifest.permission.ACCESS_MEDIA_LOCATION)

    fun hasCallBasics(c: Context) =
        granted(c, Manifest.permission.READ_PHONE_STATE) && granted(c, Manifest.permission.ANSWER_PHONE_CALLS)

    /** Our accessibility service is switched on in Settings (reads the secure setting, so it works before the service binds). */
    fun hasClipboardService(c: Context): Boolean {
        val enabled = android.provider.Settings.Secure.getString(c.contentResolver, android.provider.Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
        val me = android.content.ComponentName(c, com.mydroid.android.clip.ClipAccessibilityService::class.java)
        return enabled.split(':').any { it.isNotBlank() && android.content.ComponentName.unflattenFromString(it) == me }
    }

    fun hasSmsAccess(c: Context) = granted(c, Manifest.permission.RECEIVE_SMS)

    fun hasSmsHistoryAccess(c: Context) = granted(c, Manifest.permission.READ_SMS) && granted(c, Manifest.permission.SEND_SMS)

    fun hasDialAccess(c: Context) = granted(c, Manifest.permission.CALL_PHONE)

    fun hasNotificationAccess(c: Context): Boolean =
        NotificationManagerCompat.getEnabledListenerPackages(c).contains(c.packageName)

    fun canPostNotifications(c: Context): Boolean =
        if (Build.VERSION.SDK_INT >= 33) granted(c, Manifest.permission.POST_NOTIFICATIONS)
        else NotificationManagerCompat.from(c).areNotificationsEnabled()

    fun isBackgroundRestricted(c: Context): Boolean =
        c.getSystemService(ActivityManager::class.java).isBackgroundRestricted
}

object Features {
    fun report(c: Context, s: Settings, callAudioEver: Boolean = false, instantCopy: Boolean = false): FeatureReport {
        fun st(enabled: Boolean, ok: Boolean) = when {
            !enabled -> FeatureState.Off
            ok -> FeatureState.On
            else -> FeatureState.NeedsPermission
        }
        return FeatureReport(
            states = mapOf(
                Feature.Notifications to st(s.notifications, Perms.hasNotificationAccess(c)),
                Feature.Photos to st(s.photos, Perms.hasPhotoAccess(c)),
                Feature.Calls to st(s.calls, Perms.hasCallBasics(c)),
                // Needs no Android permission: select text -> "Send to Mac", the notification button, tile and share target all work.
                Feature.Clipboard to st(s.clipboard, true),
                Feature.Sms to st(s.smsHistory, Perms.hasSmsHistoryAccess(c)),
            ),
            otp = st(s.notifications, Perms.hasSmsAccess(c)),
            callAudio = com.mydroid.android.callaudio.CallAudioSetup.status(c, s),
            callAudioEver = callAudioEver || s.callAudio,
            instantCopy = instantCopy,
            a11yEnabled = Perms.hasClipboardService(c),
            walkAway = com.mydroid.android.walkaway.WalkAway.status(c, s),
            presence = com.mydroid.android.presence.Presence.status(c),
            codesFromApps = com.mydroid.android.presence.Presence.isWatch(c),
            bluetoothOn = com.mydroid.android.presence.Presence.bluetoothOn(c),
            backgroundRestricted = Perms.isBackgroundRestricted(c),
            batteryOptimizationExempt = c.getSystemService(PowerManager::class.java)
                .isIgnoringBatteryOptimizations(c.packageName),
            postNotifications = Perms.canPostNotifications(c),
            photosPartial = Build.VERSION.SDK_INT >= 34 && s.photos && Perms.hasPhotoAccess(c) && !Perms.hasFullPhotoAccess(c),
            dial = Perms.hasDialAccess(c),
            callsMissingOptional = s.calls && Perms.hasCallBasics(c) &&
                !(Perms.granted(c, Manifest.permission.READ_CALL_LOG) && Perms.granted(c, Manifest.permission.READ_CONTACTS)),
        )
    }
}


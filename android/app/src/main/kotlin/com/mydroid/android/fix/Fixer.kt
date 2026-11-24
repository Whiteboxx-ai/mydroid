package com.mydroid.android.fix

import android.annotation.SuppressLint
import android.app.KeyguardManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import com.mydroid.android.Channels
import com.mydroid.android.Perms
import com.mydroid.android.R
import com.mydroid.android.callaudio.CallAudioSetup
import com.mydroid.android.presence.Presence
import com.mydroid.android.ui.MainActivity

/** `fix.open`: the Mac asks us to nudge the user to the right Android screen. */
object Fixer {
    const val EXTRA_FIX = "fix"
    private const val ID = 4201

    /** Developer options, or About phone with the 7-taps hint when they're still locked. */
    private fun developerOptions(c: Context, wireless: Boolean): Triple<String, String, Intent> {
        val dev = Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
        return when {
            !CallAudioSetup.devOptions(c) || c.packageManager.resolveActivity(dev, 0) == null -> Triple(
                "Unlock Developer options",
                "Tap Build number 7 times",
                Intent(Settings.ACTION_DEVICE_INFO_SETTINGS),
            )
            wireless -> Triple(
                "Set up Wireless debugging",
                "Turn it on, then pair with QR code",
                dev,
            )
            else -> Triple("Open Developer options", "For call audio setup", dev)
        }
    }

    private fun tryDirect(c: Context, intent: Intent) {
        val direct = Presence.hasAssociation(c) &&
            c.getSystemService(PowerManager::class.java).isInteractive &&
            !c.getSystemService(KeyguardManager::class.java).isKeyguardLocked
        if (!direct) return
        try { c.startActivity(intent) } catch (e: Exception) { Log.w("MydroidFix", "direct open failed: ${e.javaClass.simpleName}") }
    }

    @SuppressLint("MissingPermission")
    fun post(c: Context, what: String) {
        val (title, text, intent) = when (what) {
            "notifications" -> Triple(
                "Allow notification access",
                "Tap to reply from your Mac",
                Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS),
            )
            "background" -> Triple(
                "Stay connected",
                "Tap, then check background activity in Battery settings",
                Oem.appDetails(c),
            )
            "photos" -> Triple(
                "Allow photo access",
                "Tap to sync photos to your Mac",
                Intent(c, MainActivity::class.java).putExtra(EXTRA_FIX, "photos"),
            )
            "calls" -> Triple(
                "Allow phone access",
                "Tap to show calls on your Mac",
                Intent(c, MainActivity::class.java).putExtra(EXTRA_FIX, "calls"),
            )
            "sms" -> Triple(
                "Allow text access",
                "Tap to use texts on your Mac",
                Intent(c, MainActivity::class.java).putExtra(EXTRA_FIX, "sms"),
            )
            "dial" -> Triple(
                "Allow calling",
                "Tap to call from your Mac",
                Intent(c, MainActivity::class.java).putExtra(EXTRA_FIX, "dial"),
            )
            "devoptions", "wireless_debugging" -> developerOptions(c, what == "wireless_debugging")
            else -> return
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        // Mac call audio setup (PROTOCOL.md 8.2): open the screen straight away when Android lets us (companion association,
        // screen on and unlocked). The notification below is the always-works path and carries the hint.
        if (what == "devoptions" || what == "wireless_debugging") tryDirect(c, intent)
        val pi = PendingIntent.getActivity(c, what.hashCode(), intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val n = NotificationCompat.Builder(c, Channels.FIXES)
            .setSmallIcon(R.drawable.ic_stat_mydroid)
            .setContentTitle(title).setContentText(text)
            .setContentIntent(pi).setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()
        if (Perms.canPostNotifications(c)) c.getSystemService(NotificationManager::class.java).notify(ID + what.hashCode() % 100, n)
    }
}

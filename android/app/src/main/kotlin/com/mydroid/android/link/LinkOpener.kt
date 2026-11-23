package com.mydroid.android.link

import android.annotation.SuppressLint
import android.app.KeyguardManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import com.mydroid.android.Channels
import com.mydroid.android.Perms
import com.mydroid.android.R
import com.mydroid.android.presence.Presence
import com.mydroid.protocol.Links

/** Incoming `link.open` (PROTOCOL.md 7.4). Only http, https and mailto, ever. */
object LinkOpener {
    private const val TAG = "MydroidLink"

    /** True if the link was allowed (opened or offered), false if refused. Never logs the URL. */
    @SuppressLint("MissingPermission")
    fun open(c: Context, raw: String?): Boolean {
        val url = Links.safe(raw) ?: run { Log.w(TAG, "link.open refused (scheme not allowed)"); return false }
        val view = Intent(Intent.ACTION_VIEW, Uri.parse(url)).addCategory(Intent.CATEGORY_BROWSABLE).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val scheme = url.substringBefore(':').lowercase()
        // A CDM-associated app may start activities from the background. Only worth it with the screen on and unlocked.
        val canDirect = Presence.hasAssociation(c) &&
            c.getSystemService(PowerManager::class.java).isInteractive &&
            !c.getSystemService(KeyguardManager::class.java).isKeyguardLocked
        if (canDirect) {
            try {
                c.startActivity(view)
                Log.i(TAG, "link.open direct scheme=$scheme")
                return true
            } catch (e: Exception) {
                Log.w(TAG, "direct open failed: ${e.javaClass.simpleName}")
            }
        }
        val pi = PendingIntent.getActivity(c, url.hashCode(), view, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val n = NotificationCompat.Builder(c, Channels.LINKS)
            .setSmallIcon(R.drawable.ic_stat_mydroid)
            .setContentTitle("Link from your Mac").setContentText(url)
            .setContentIntent(pi).setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE).setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()
        if (Perms.canPostNotifications(c)) {
            c.getSystemService(NotificationManager::class.java).notify(4300 + (url.hashCode() and 0xff), n)
            Log.i(TAG, "link.open notification scheme=$scheme")
        }
        return true
    }
}

package com.mydroid.android.mac

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import com.mydroid.android.Channels
import com.mydroid.android.Perms
import com.mydroid.android.R
import com.mydroid.android.ui.MainActivity

/** "Presenting on your Mac? Tap for clicker" (PROTOCOL.md 10): quiet, no sound, gone when the slideshow ends. */
object PresenterNotice {
    private const val ID = 4200
    const val EXTRA_OPEN_REMOTE = "open_remote"
    const val MODE_PRESENTER = "presenter"

    fun post(c: Context, app: String) {
        if (!Perms.canPostNotifications(c)) return
        val open = PendingIntent.getActivity(
            c, 2, Intent(c, MainActivity::class.java).putExtra(EXTRA_OPEN_REMOTE, MODE_PRESENTER),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n = NotificationCompat.Builder(c, Channels.PRESENTING)
            .setSmallIcon(R.drawable.ic_stat_mydroid)
            .setContentTitle("Presenting on your Mac?")
            .setContentText("Tap for clicker")
            .apply { if (app.isNotBlank()) setSubText(app) }
            .setSilent(true).setOnlyAlertOnce(true).setAutoCancel(true).setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setTimeoutAfter(4 * 60 * 60 * 1000L)
            .setContentIntent(open).build()
        runCatching { c.getSystemService(NotificationManager::class.java).notify(ID, n) }
    }

    fun cancel(c: Context) {
        runCatching { c.getSystemService(NotificationManager::class.java).cancel(ID) }
    }
}

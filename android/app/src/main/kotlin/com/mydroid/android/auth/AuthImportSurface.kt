package com.mydroid.android.auth

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import com.mydroid.android.Channels
import com.mydroid.android.R

/**
 * Brings the import review to the user: a high-priority notification (heads-up, and full screen when the phone is idle) that opens
 * [com.mydroid.android.ui.AuthImportActivity]. The text names the Mac and a count, never an issuer or account. If the app is already in
 * front, the screen is opened straight away as well.
 */
class AuthImportSurface(private val ctx: Context, private val appVisible: () -> Boolean) : ImportSurface {
    private val nm get() = ctx.getSystemService(NotificationManager::class.java)

    override fun show(count: Int, mac: String): Boolean {
        val blocked = !nm.areNotificationsEnabled() || nm.getNotificationChannel(Channels.AUTH)?.importance == NotificationManager.IMPORTANCE_NONE
        if (blocked) return false
        val open = Intent(ctx, com.mydroid.android.ui.AuthImportActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val review = PendingIntent.getActivity(ctx, REQUEST, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val cancel = PendingIntent.getBroadcast(
            ctx, REQUEST + 1, Intent(ctx, AuthActionReceiver::class.java).setAction(AuthActionReceiver.IMPORT_CANCEL).setPackage(ctx.packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val title = "Add ${if (count == 1) "1 account" else "$count accounts"}?"
        val body = "From $mac. Review before adding."
        val public = NotificationCompat.Builder(ctx, Channels.AUTH).setSmallIcon(R.drawable.ic_stat_mydroid)
            .setContentTitle("Account import").setContentText("Unlock to review").build()
        val n = NotificationCompat.Builder(ctx, Channels.AUTH)
            .setSmallIcon(R.drawable.ic_stat_mydroid)
            .setContentTitle(title).setContentText(body).setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH).setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE).setPublicVersion(public)
            .setContentIntent(review).setFullScreenIntent(review, true)
            .setAutoCancel(true).setOnlyAlertOnce(true).setTimeoutAfter(com.mydroid.protocol.auth.AuthImportWire.TIMEOUT_MS)
            .addAction(0, "Review", review).addAction(0, "Cancel", cancel)
            .build()
        runCatching { nm.notify(NOTIF_ID, n) }.onFailure { return false }
        if (appVisible()) runCatching { ctx.startActivity(open) }
        return true
    }

    override fun dismiss() { runCatching { nm.cancel(NOTIF_ID) } }

    private companion object {
        const val NOTIF_ID = 4590 // the code-request notifications use 4600..5499
        const val REQUEST = 4590
    }
}

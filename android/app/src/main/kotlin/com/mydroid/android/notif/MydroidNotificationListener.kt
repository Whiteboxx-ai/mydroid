package com.mydroid.android.notif

import android.content.ComponentName
import android.os.Build
import android.util.Log
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import com.mydroid.android.manager
import com.mydroid.android.net.ConnectionService
import com.mydroid.android.presence.Presence

/** The system rebinds this service, which also keeps our process (and the Mac connection) alive. */
class MydroidNotificationListener : NotificationListenerService() {
    private var watchAssociationAtBind: Int? = null

    override fun onListenerConnected() {
        watchAssociationAtBind = Presence.watchAssociationId(this)
        Log.i(TAG, "listener connected companion=${watchAssociationAtBind != null}")
        val m = manager()
        m.notifs.listener = this
        m.start()
        ConnectionService.start(this)
        m.onListenerReady()
    }

    override fun onListenerDisconnected() {
        val bridge = manager().notifs
        if (bridge.listener === this) bridge.listener = null
        try {
            requestRebind(ComponentName(this, MydroidNotificationListener::class.java))
        } catch (_: Exception) {
        }
    }

    /** Android 15+ can keep the trust decision from before the companion association was granted. */
    fun refreshCompanionAccess() {
        if (Build.VERSION.SDK_INT < 35) return
        val association = Presence.watchAssociationId(this) ?: return
        if (association == watchAssociationAtBind) return
        try {
            // onListenerDisconnected requests a new bind using the notification access the user already granted.
            requestUnbind()
            watchAssociationAtBind = association
        } catch (e: Exception) {
            Log.w(TAG, "Companion listener refresh failed: ${e.javaClass.simpleName}")
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.notification?.category == android.app.Notification.CATEGORY_CALL) manager().onCallNotification(sbn)
        manager().notifs.onPosted(sbn)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        manager().notifs.onRemoved(sbn)
    }

    private companion object { const val TAG = "MydroidNotif" }
}

package com.mydroid.android.notif

import android.content.ComponentName
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import com.mydroid.android.manager
import com.mydroid.android.net.ConnectionService

/** The system rebinds this service, which also keeps our process (and the Mac connection) alive. */
class MydroidNotificationListener : NotificationListenerService() {
    override fun onListenerConnected() {
        val m = manager()
        m.notifs.listener = this
        m.start()
        ConnectionService.start(this)
        m.onListenerReady()
    }

    override fun onListenerDisconnected() {
        manager().notifs.listener = null
        try {
            requestRebind(ComponentName(this, MydroidNotificationListener::class.java))
        } catch (_: Exception) {
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.notification?.category == android.app.Notification.CATEGORY_CALL) manager().onCallNotification(sbn)
        manager().notifs.onPosted(sbn)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        manager().notifs.onRemoved(sbn)
    }
}

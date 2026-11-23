package com.mydroid.android.net

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.mydroid.android.Channels
import com.mydroid.android.clip.ClipSendActivity
import com.mydroid.android.R
import com.mydroid.android.manager
import com.mydroid.android.ui.MainActivity
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

/** Foreground service (type connectedDevice) that keeps the Mac connection alive. */
class ConnectionService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val m = manager()
        if (!m.store.isPaired && m.state.value.link != Link.Confirm && m.state.value.link != Link.Connecting) {
            stopSelf(); return START_NOT_STICKY
        }
        if (!m.serviceAllowed()) { stopSelf(); return START_NOT_STICKY } // Mac not nearby (BLE presence)
        try {
            ServiceCompat.startForeground(
                this, ID, build(this, m.state.value.link, m.state.value.macName, m.state.value.settings?.clipboard == true),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } catch (e: Exception) {
            stopSelf(); return START_NOT_STICKY
        }
        running = true
        m.start()
        m.refreshWalkAway()
        scope.coroutineContext.cancelChildren()
        scope.launch {
            m.state.map { Triple(it.link, it.macName, it.settings?.clipboard == true) }.distinctUntilChanged().collect { (link, name, clip) ->
                getSystemService(NotificationManager::class.java).notify(ID, build(this@ConnectionService, link, name, clip))
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        runCatching { manager().refreshWalkAway() } // the beacon only lives while this service does
        scope.cancel()
        super.onDestroy()
    }

    companion object {
        private const val ID = 4100

        /** True while the foreground service is up. The walk-away beacon follows it (PROTOCOL.md 12). */
        @Volatile var running = false
            private set

        fun build(c: Context, link: Link, mac: String, clipboard: Boolean = false): Notification {
            val text = when (link) {
                Link.Connected -> "Connected to $mac"
                Link.Unpaired -> "Not paired"
                else -> "Looking for your Mac…"
            }
            val open = PendingIntent.getActivity(c, 0, Intent(c, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            // "Send clipboard": the permission-free path for text already copied. Opens the transparent activity, which reads the
            // clipboard once it has focus (Android only lets the focused app read it), sends, and finishes.
            val send = PendingIntent.getActivity(
                c, 1, Intent(c, ClipSendActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            return NotificationCompat.Builder(c, Channels.CONNECTION)
                .apply { if (link == Link.Connected && clipboard) addAction(0, "Send clipboard", send) }
                .setSmallIcon(R.drawable.ic_stat_mydroid)
                .setContentTitle(text)
                .setOngoing(true).setSilent(true).setOnlyAlertOnce(true).setShowWhen(false)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
                .setContentIntent(open).build()
        }

        fun start(c: Context) {
            if (!c.manager().store.isPaired && c.manager().state.value.link != Link.Confirm) return
            if (!c.manager().serviceAllowed()) return
            try {
                ContextCompat.startForegroundService(c, Intent(c, ConnectionService::class.java))
            } catch (e: Exception) {
                // Background start not allowed right now (e.g. after a cold boot); the listener
                // service and the next app open will retry. The manager itself keeps running.
            }
        }

        fun stop(c: Context) {
            c.stopService(Intent(c, ConnectionService::class.java))
        }
    }
}

package com.mydroid.android.boot

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.mydroid.android.callaudio.CallAudioSetup
import com.mydroid.android.manager
import com.mydroid.android.net.ConnectionService

/** Start the connection after boot and after the app is updated. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED && intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val m = context.manager()
        if (!m.store.isPaired) return
        m.start()
        CallAudioSetup.keepAlive(context, m.settings) // Wireless debugging doesn't always survive a reboot; only acts if call audio is on and granted
        m.refreshPresence(force = true) // scans don't survive a reboot or an app update
        ConnectionService.start(context)
    }
}

package com.mydroid.android

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context

object Channels {
    const val CONNECTION = "connection"
    const val FILES = "files"
    const val FIND = "find"
    const val FIXES = "fixes"
    const val LINKS = "links"
    const val OPEN = "open"
    const val PRESENTING = "presenting"
    const val AUTH = "auth_requests"

    fun ensure(c: Context) {
        val nm = c.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CONNECTION, "Connection", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shows while connected"
                setShowBadge(false)
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(FILES, "Files from your Mac", NotificationManager.IMPORTANCE_DEFAULT),
        )
        nm.createNotificationChannel(
            NotificationChannel(FIND, "Find my phone", NotificationManager.IMPORTANCE_HIGH).apply {
                setSound(null, null)
                enableVibration(false)
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(FIXES, "Needs attention", NotificationManager.IMPORTANCE_DEFAULT),
        )
        nm.createNotificationChannel(
            NotificationChannel(LINKS, "Links from your Mac", NotificationManager.IMPORTANCE_HIGH),
        )
        nm.createNotificationChannel(
            NotificationChannel(OPEN, "Open on this phone", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Tap to finish opening from your Mac"
                setShowBadge(false)
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(AUTH, "Code requests", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Approve before your Mac fills a code"
                setShowBadge(false)
                lockscreenVisibility = android.app.Notification.VISIBILITY_PRIVATE
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(PRESENTING, "Presenting", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Clicker shortcut during a slideshow"
                setShowBadge(false)
            },
        )
    }
}

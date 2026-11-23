package com.mydroid.android

import android.app.Application
import android.content.Context
import com.mydroid.android.net.ConnectionManager

class MydroidApp : Application() {
    val manager: ConnectionManager by lazy { ConnectionManager(this) }

    override fun onCreate() {
        super.onCreate()
        Channels.ensure(this)
        com.mydroid.android.callaudio.CallAudioSetup.deleteStaleVerify(this)
        if (manager.store.isPaired) manager.start()
    }
}

fun Context.manager(): ConnectionManager = (applicationContext as MydroidApp).manager

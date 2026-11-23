package com.mydroid.android.clip

import android.app.Activity
import android.os.Bundle
import android.widget.Toast
import com.mydroid.android.manager

/**
 * Transparent activity opened by the Quick Settings tile. Android only lets the focused app read the
 * clipboard, so we wait for window focus, read once, send, and finish.
 */
class ClipSendActivity : Activity() {
    private var done = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || done) return
        done = true
        val msg = manager().sendClipboardNow(this)
        Toast.makeText(applicationContext, msg, Toast.LENGTH_SHORT).show()
        finish()
        overridePendingTransition(0, 0)
    }
}

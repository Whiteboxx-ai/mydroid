package com.mydroid.android.auth

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.mydroid.android.manager

/** Approve and Deny on the code-request notification. Not exported; the intents are explicit and immutable. */
class AuthActionReceiver : BroadcastReceiver() {
    override fun onReceive(c: Context, i: Intent) {
        if (i.action == IMPORT_CANCEL) { c.manager().auth.importer.cancel(); return }
        val req = i.getStringExtra(EXTRA_REQ) ?: return
        when (i.action) {
            APPROVE -> c.manager().auth.bridge.resolve(req, true)
            DENY -> c.manager().auth.bridge.resolve(req, false)
        }
    }

    companion object {
        const val APPROVE = "com.mydroid.android.auth.APPROVE"
        const val DENY = "com.mydroid.android.auth.DENY"
        /** "Cancel" on the account-import notification (PROTOCOL.md 14.4). */
        const val IMPORT_CANCEL = "com.mydroid.android.auth.IMPORT_CANCEL"
        const val EXTRA_REQ = "req"
    }
}

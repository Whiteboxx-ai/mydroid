package com.mydroid.android.auth

import android.content.Context
import com.mydroid.protocol.auth.ApprovalPolicy

/** Authenticator settings. Phone settings: they survive re-pairing. */
class AuthPrefs(context: Context) {
    private val p = context.applicationContext.getSharedPreferences("mydroid_auth", Context.MODE_PRIVATE)

    /** Ask for a fingerprint, face or screen lock before the list shows codes. On by default. */
    var requireBiometric: Boolean
        get() = p.getBoolean("requireBio", true)
        set(v) = p.edit().putBoolean("requireBio", v).apply()

    var approveMode: ApprovalPolicy.Mode
        get() = if (p.getBoolean("autoApprove", false)) ApprovalPolicy.Mode.Auto else ApprovalPolicy.Mode.Ask
        set(v) = p.edit().putBoolean("autoApprove", v == ApprovalPolicy.Mode.Auto).apply()

    var autoMinutes: Int
        get() = p.getInt("autoMinutes", 5).coerceIn(1, 60)
        set(v) = p.edit().putInt("autoMinutes", v.coerceIn(1, 60)).apply()

    /** 0 = never. */
    var lastBackupAt: Long
        get() = p.getLong("lastBackupAt", 0)
        set(v) = p.edit().putLong("lastBackupAt", v).apply()

    /** The one-time "make a backup" nudge was dismissed. */
    var nudgeDismissed: Boolean
        get() = p.getBoolean("nudgeDismissed", false)
        set(v) = p.edit().putBoolean("nudgeDismissed", v).apply()

    /** Last time the user unlocked the phone (USER_PRESENT), for "unlocked within N minutes". */
    var lastUnlockedAt: Long
        get() = p.getLong("lastUnlockedAt", 0)
        set(v) = p.edit().putLong("lastUnlockedAt", v).apply()

    fun clear() = p.edit().clear().apply()
}

/** What Home and Settings need to show, without any secret or code. */
data class AuthUi(
    val count: Int = 0,
    val unreadable: Boolean = false,
    val requireBiometric: Boolean = true,
    val approveMode: ApprovalPolicy.Mode = ApprovalPolicy.Mode.Ask,
    val autoMinutes: Int = 5,
    val lastBackupAt: Long = 0,
    /** At least one account, no backup yet, nudge not dismissed. */
    val nudge: Boolean = false,
    /** "Your Mac nearby" is set up, which "Approve automatically" needs to prove the Mac is here. */
    val presenceReady: Boolean = false,
    /** The phone has a fingerprint, face or screen lock to gate with. */
    val canGate: Boolean = true,
)

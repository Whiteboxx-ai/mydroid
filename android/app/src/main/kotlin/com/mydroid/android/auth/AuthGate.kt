package com.mydroid.android.auth

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * The biometric gate for viewing codes. Open after a successful prompt; closes again when the app has been in the background
 * for [RELOCK_MS]. Platform BiometricPrompt: biometric or the screen lock (PIN, pattern, password) as the fallback.
 */
class AuthGate(private val now: () -> Long = System::currentTimeMillis) {
    private val _open = MutableStateFlow(false)
    val open: StateFlow<Boolean> get() = _open
    @Volatile private var backgroundedAt = 0L
    private var cancel: CancellationSignal? = null

    fun onBackground() { backgroundedAt = now() }

    /** App is back in front: lock if it was away for 60 s or more. */
    fun onForeground() {
        val t = backgroundedAt
        backgroundedAt = 0
        if (t != 0L && now() - t >= RELOCK_MS) lock()
    }

    fun lock() { _open.value = false }
    fun unlock() { _open.value = true }

    /**
     * Shows the system prompt. [onResult] gets true on success. Without any screen lock there is nothing to ask, so it opens.
     * [unlockGate] false is for a one-off confirmation (an account import): it proves the user without opening the Authenticator list.
     * [onError] gets the BiometricPrompt error code on a failure, so a caller can tell a lockout from a user who just backed out.
     */
    fun prompt(activity: Activity, title: String, subtitle: String, unlockGate: Boolean = true, onError: ((Int) -> Unit)? = null, onResult: (Boolean) -> Unit) {
        if (!canGate(activity)) { if (unlockGate) unlock(); onResult(true); return }
        cancel?.cancel()
        val signal = CancellationSignal().also { cancel = it }
        val builder = BiometricPrompt.Builder(activity).setTitle(title).setSubtitle(subtitle)
        if (Build.VERSION.SDK_INT >= 30) builder.setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.DEVICE_CREDENTIAL)
        else @Suppress("DEPRECATION") builder.setDeviceCredentialAllowed(true)
        builder.build().authenticate(signal, activity.mainExecutor, object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) { if (unlockGate) unlock(); onResult(true) }
            override fun onAuthenticationError(errorCode: Int, errString: CharSequence?) { onError?.invoke(errorCode); onResult(false) }
        })
    }

    fun cancelPrompt() { cancel?.cancel(); cancel = null }

    companion object {
        const val RELOCK_MS = 60_000L

        /** BiometricPrompt's BIOMETRIC_ERROR_LOCKOUT and BIOMETRIC_ERROR_LOCKOUT_PERMANENT: too many wrong tries. */
        fun isLockout(errorCode: Int) = errorCode == 7 || errorCode == 9

        /** A fingerprint, face or screen lock exists to gate with. */
        fun canGate(c: Context): Boolean = try {
            val km = c.getSystemService(KeyguardManager::class.java)
            if (Build.VERSION.SDK_INT >= 30) {
                c.getSystemService(BiometricManager::class.java)
                    .canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.DEVICE_CREDENTIAL) == BiometricManager.BIOMETRIC_SUCCESS
            } else km.isDeviceSecure
        } catch (e: Exception) { false }
    }
}

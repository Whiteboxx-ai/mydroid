package com.mydroid.android.calls

import android.annotation.SuppressLint
import android.app.Notification
import android.app.Person
import android.service.notification.StatusBarNotification
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.ContactsContract
import android.telecom.TelecomManager
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import android.media.AudioManager
import android.Manifest
import com.mydroid.android.Perms
import com.mydroid.protocol.Message
import kotlinx.serialization.json.put
import java.util.UUID

/** Watches phone state and reports `call.state`. */
class CallMonitor(private val ctx: Context, private val send: (Message) -> Boolean) {
    private val tm = ctx.getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
    private val main = Handler(Looper.getMainLooper())
    private var running = false
    private var callback: Any? = null
    private var legacy: PhoneStateListener? = null
    private var receiver: BroadcastReceiver? = null

    private var last = TelephonyManager.CALL_STATE_IDLE
    @Volatile var callId: String? = null
        private set
    private var incoming = false
    @Volatile private var number: String? = null
    private var ringingSent = false
    /** Last state sent for the current call, so a late-arriving number can update it. */
    @Volatile private var sentState: String? = null
    /** Caller label from the dialer's own ongoing-call notification (works for outgoing calls on any OEM dialer). */
    @Volatile private var dialerLabel: String? = null
    private val delayedRinging = Runnable { emitRinging() }

    @Synchronized
    @SuppressLint("MissingPermission")
    fun start() {
        if (running || !Perms.granted(ctx, Manifest.permission.READ_PHONE_STATE)) return
        running = true
        last = TelephonyManager.CALL_STATE_IDLE
        // The number is only delivered through the broadcast on modern Android (needs READ_CALL_LOG).
        receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                @Suppress("DEPRECATION")
                val n = i.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER)?.takeIf { it.isNotBlank() } ?: return
                onNumber(n)
            }
        }
        ctx.registerReceiver(receiver, IntentFilter(TelephonyManager.ACTION_PHONE_STATE_CHANGED), Context.RECEIVER_EXPORTED)
        if (Build.VERSION.SDK_INT >= 31) {
            val cb = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
                override fun onCallStateChanged(state: Int) = handle(state)
            }
            callback = cb
            tm.registerTelephonyCallback(ctx.mainExecutor, cb)
        } else {
            @Suppress("DEPRECATION")
            val l = object : PhoneStateListener() {
                @Deprecated("Deprecated in Java")
                override fun onCallStateChanged(state: Int, phoneNumber: String?) {
                    handle(state)
                    if (!phoneNumber.isNullOrBlank()) onNumber(phoneNumber)
                }
            }
            legacy = l
            main.post { @Suppress("DEPRECATION") tm.listen(l, PhoneStateListener.LISTEN_CALL_STATE) }
        }
    }

    @Synchronized
    fun stop() {
        if (!running) return
        running = false
        if (Build.VERSION.SDK_INT >= 31) (callback as? TelephonyCallback)?.let { tm.unregisterTelephonyCallback(it) }
        else legacy?.let { l -> main.post { @Suppress("DEPRECATION") tm.listen(l, PhoneStateListener.LISTEN_NONE) } }
        callback = null; legacy = null
        receiver?.let { runCatching { ctx.unregisterReceiver(it) } }
        receiver = null
        main.removeCallbacks(delayedRinging)
    }

    @Synchronized
    private fun handle(state: Int) {
        if (state == last) return
        val prev = last
        last = state
        when (state) {
            TelephonyManager.CALL_STATE_RINGING -> {
                callId = UUID.randomUUID().toString(); incoming = true; ringingSent = false
                // wait briefly: the broadcast with the number usually lands just after the callback
                main.postDelayed(delayedRinging, 400)
            }
            TelephonyManager.CALL_STATE_OFFHOOK -> {
                if (callId == null || prev == TelephonyManager.CALL_STATE_IDLE) {
                    callId = UUID.randomUUID().toString(); incoming = false
                }
                main.removeCallbacks(delayedRinging)
                emit("active")
            }
            TelephonyManager.CALL_STATE_IDLE -> {
                main.removeCallbacks(delayedRinging)
                if (callId != null) emit("ended")
                callId = null; number = null; ringingSent = false; sentState = null; dialerLabel = null
            }
        }
    }

    /**
     * The number arrives through the PHONE_STATE broadcast, usually a moment *after* the TelephonyCallback.
     * For outgoing calls we've already sent "active" by then, so re-send the current state with the
     * number and contact name instead of leaving the Mac on "Unknown caller" until hang-up.
     */
    /**
     * Fallback for outgoing calls, where Android often never broadcasts the number: every dialer posts an
     * ongoing CATEGORY_CALL notification naming the other party. Only the default dialer's is trusted, so
     * VoIP apps' call notifications can't relabel a cellular call.
     */
    @Synchronized
    fun onCallNotification(sbn: StatusBarNotification) {
        val n = sbn.notification ?: return
        if (n.category != Notification.CATEGORY_CALL) return
        val dialer = runCatching { (ctx.getSystemService(Context.TELECOM_SERVICE) as TelecomManager).defaultDialerPackage }.getOrNull()
        if (dialer != null && sbn.packageName != dialer && sbn.packageName != "com.android.server.telecom") return
        val person: Person? = if (Build.VERSION.SDK_INT >= 31) {
            if (Build.VERSION.SDK_INT >= 33) n.extras.getParcelable(Notification.EXTRA_CALL_PERSON, Person::class.java)
            else @Suppress("DEPRECATION") n.extras.getParcelable(Notification.EXTRA_CALL_PERSON)
        } else null
        val candidates = listOfNotNull(
            person?.name?.toString(),
            n.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString(),
            n.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString(),
        ).map { it.trim() }.filter { it.isNotEmpty() && !isStatusText(it) }
        val label = candidates.firstOrNull() ?: return
        if (label == dialerLabel) return
        dialerLabel = label
        if (looksLikeNumber(label)) { onNumber(label); return }
        val st = sentState ?: return
        if (callId != null && last != TelephonyManager.CALL_STATE_IDLE) emit(st)
    }

    private fun looksLikeNumber(s: String) = s.count { it.isDigit() } >= 3 && s.all { it.isDigit() || it in "+-() ." }

    /** Dialer status lines ("Calling…", "Ongoing call", "0:42") rather than a person. */
    private fun isStatusText(s: String): Boolean {
        val l = s.lowercase()
        if (Regex("^\\d{1,2}:\\d{2}(:\\d{2})?$").matches(l)) return true
        return listOf("calling", "dialing", "dialling", "ongoing call", "on hold", "incoming call", "outgoing call",
            "call ended", "connecting", "wi-fi call", "hd call", "mobile network").any { l.startsWith(it) }
    }

    @Synchronized
    private fun onNumber(n: String) {
        if (n == number) return
        number = n
        val st = sentState ?: return
        if (callId != null && last != TelephonyManager.CALL_STATE_IDLE) emit(st)
    }

    @Synchronized
    private fun emitRinging() {
        if (last == TelephonyManager.CALL_STATE_RINGING && callId != null && !ringingSent) {
            ringingSent = true
            emit("ringing")
        }
    }

    private fun emit(state: String) {
        val id = callId ?: return
        sentState = if (state == "ended") null else state
        val num = number
        val name = num?.let { lookupName(it) } ?: dialerLabel?.takeIf { !looksLikeNumber(it) }
        send(
            Message.of("call.state") {
                put("callId", id); put("state", state); put("incoming", incoming)
                if (num != null) put("number", num)
                if (name != null) put("name", name)
            },
        )
    }

    private fun lookupName(number: String): String? {
        if (!Perms.granted(ctx, Manifest.permission.READ_CONTACTS)) return null
        return try {
            val uri = Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(number))
            ctx.contentResolver.query(uri, arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            }
        } catch (e: Exception) {
            null
        }
    }
}

/** `call.action`: answer, decline/end through TelecomManager. Audio stays on the phone in v1. */
class CallControl(private val ctx: Context) {
    @SuppressLint("MissingPermission")
    @Suppress("DEPRECATION")
    fun perform(action: String): Boolean {
        if (!Perms.granted(ctx, Manifest.permission.ANSWER_PHONE_CALLS)) return false
        val tm = ctx.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
        val audio = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        return try {
            when (action) {
                "answer" -> { tm.acceptRingingCall(); true }
                "decline", "end" -> tm.endCall()
                "mute" -> { audio.isMicrophoneMute = true; true }
                "unmute" -> { audio.isMicrophoneMute = false; true }
                else -> false
            }
        } catch (e: SecurityException) {
            false
        }
    }
}

package com.mydroid.android.sms

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import com.mydroid.android.manager
import com.mydroid.protocol.SmsAssembler
import com.mydroid.protocol.SmsPart

/**
 * Android 15+ hides OTP text from notification listeners, so we read the SMS itself (RECEIVE_SMS) and
 * hand it to NotifBridge, which matches it to the redacted notification or posts the code on its own.
 * Nothing about the message is logged.
 */
class SmsOtpReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val m = context.manager()
        if (!m.store.isPaired || !m.store.settings.notifications) return
        val parts = Telephony.Sms.Intents.getMessagesFromIntent(intent)
            .mapNotNull { sm -> sm.originatingAddress?.let { SmsPart(it, sm.messageBody ?: "") } }
        for (sms in SmsAssembler.assemble(parts)) m.notifs.onSms(sms.address, sms.body, System.currentTimeMillis())
    }
}

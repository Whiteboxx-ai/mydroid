package com.mydroid.android.notif

import android.app.Notification
import android.content.Context
import android.os.UserHandle
import android.service.notification.StatusBarNotification
import com.mydroid.protocol.Message
import com.mydroid.protocol.Redaction
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class NotifBridgeTest {
    private val context: Context = RuntimeEnvironment.getApplication()
    private val sent = LinkedBlockingQueue<Message>()
    private val bridge = NotifBridge(context, send = { sent.add(it) }, enabled = { true })

    @Test fun hiddenMailDoesNotLeakExpandedTextOrExtractACode() {
        val fields = checkNotNull(bridge.describe(mail(
            title = "Example verification code",
            text = Redaction.ENGLISH,
            expanded = "Your verification code is 2048. https://example.com/verify",
        )))
        assertEquals(Redaction.ENGLISH, fields["text"]?.jsonPrimitive?.content)
        assertNull(fields["otp"])
        assertNull(fields["links"])
    }

    @Test fun hiddenMailDoesNotClaimAnSmsFromTheSameSender() {
        bridge.onSms("EXAMPLE", "Your OTP is 482196", System.currentTimeMillis())
        bridge.onPosted(mail(title = "Example", text = Redaction.ENGLISH))

        val notification = checkNotNull(sent.poll(2, TimeUnit.SECONDS))
        assertEquals("com.google.android.gm", notification.str("pkg"))
        assertEquals(Redaction.ENGLISH, notification.str("text"))
        assertNull(notification.obj("otp"))
    }

    private fun mail(title: String, text: String, expanded: String? = null): StatusBarNotification {
        val notification = Notification.Builder(context, "mail").setContentTitle(title).setContentText(text)
        if (expanded != null) notification.setStyle(Notification.BigTextStyle().bigText(expanded))
        return StatusBarNotification(
            "com.google.android.gm", "com.google.android.gm", 1, null, 10001, 1, 0,
            notification.build(), UserHandle.getUserHandleForUid(10001), System.currentTimeMillis(),
        )
    }
}

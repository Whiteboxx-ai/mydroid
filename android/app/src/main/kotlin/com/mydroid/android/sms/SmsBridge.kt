package com.mydroid.android.sms

import android.Manifest
import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.database.ContentObserver
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Telephony
import android.telephony.SmsManager
import android.util.Log
import com.mydroid.android.Perms
import com.mydroid.android.contacts.ContactLookup
import com.mydroid.android.data.Settings
import com.mydroid.android.manager
import com.mydroid.protocol.Message
import com.mydroid.protocol.SendTracker
import com.mydroid.protocol.SmsErrors
import com.mydroid.protocol.SmsWire
import com.mydroid.protocol.ThreadChangeTracker
import com.mydroid.protocol.flexLong
import kotlinx.serialization.json.JsonPrimitive
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

private const val TAG = "MydroidSms"

/**
 * PROTOCOL.md 7.5: `sms.threads.get`, `sms.messages.get`, `sms.send`, and `sms.changed` from a ContentObserver.
 * Every entry point is meant to be called on a worker thread. Only counts and timings are logged.
 *
 * Sent messages are not written to the SMS provider here. Since Android 4.4 the platform persists text sent through
 * `SmsManager` by a non-default app itself (the same path as the default app uses), so inserting a row would show the
 * message twice; the provider change then arrives through the observer like any other.
 */
class SmsBridge(
    private val ctx: Context,
    contacts: ContactLookup,
    private val settings: () -> Settings,
    private val reply: (Message) -> Boolean,
) {
    val repo = SmsRepository(ctx, contacts)
    private val tracker = SendTracker()
    private val timers: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { Thread(it, "mydroid-sms-timer").apply { isDaemon = true } }
    private val main = Handler(Looper.getMainLooper())

    /** True when the Mac enabled SMS history and Android lets us read it. */
    fun readable(enforce: Boolean = true) = (!enforce || settings().smsHistory) && Perms.granted(ctx, Manifest.permission.READ_SMS)

    fun sendable(enforce: Boolean = true) = readable(enforce) && Perms.granted(ctx, Manifest.permission.SEND_SMS)

    private fun denied(type: String) {
        Log.i(TAG, "$type refused: permission or setting missing")
        reply(SmsWire.error("permission", type))
    }

    private fun failed(type: String, e: Exception) {
        Log.w(TAG, "$type failed: ${e.javaClass.simpleName}")
        reply(SmsWire.error(if (e is SecurityException) "permission" else "failed", type))
    }

    fun threads(m: Message, enforce: Boolean = true) {
        if (!readable(enforce)) return denied(m.type)
        val t0 = System.nanoTime()
        try {
            val page = repo.threads(SmsWire.limit(m.int("limit")), m.flexLong("before"))
            val out = SmsWire.threads(page.items)
            reply(out)
            Log.i(TAG, "sms.threads n=${page.items.size} sent=${out.arr("threads")?.size} ms=${(System.nanoTime() - t0) / 1_000_000}")
        } catch (e: Exception) {
            failed(m.type, e)
        }
    }

    fun messages(m: Message, enforce: Boolean = true) {
        if (!readable(enforce)) return denied(m.type)
        val threadId = m.flexLong("threadId") ?: return
        val t0 = System.nanoTime()
        try {
            val page = repo.messages(threadId, SmsWire.limit(m.int("limit")), m.flexLong("before"))
            val out = SmsWire.messages(threadId, page.items)
            reply(out)
            Log.i(TAG, "sms.messages n=${page.items.size} sent=${out.arr("messages")?.size} more=${page.more} ms=${(System.nanoTime() - t0) / 1_000_000}")
        } catch (e: Exception) {
            failed(m.type, e)
        }
    }

    // ------------------------------------------------------------------ sending

    private fun smsManager(): SmsManager =
        if (android.os.Build.VERSION.SDK_INT >= 31) ctx.getSystemService(SmsManager::class.java) else @Suppress("DEPRECATION") SmsManager.getDefault()

    private fun fail(clientId: String, error: String, threadId: Long? = null) {
        reply(SmsWire.sent(clientId, false, error, threadId))
    }

    fun send(m: Message, enforce: Boolean = true) {
        val clientId = m.str("clientId") ?: return
        if (!sendable(enforce)) {
            Log.i(TAG, "sms.send refused: permission or setting missing")
            reply(SmsWire.error("permission", m.type))
            return
        }
        val to = m.arr("to")?.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content?.trim()?.takeIf { s -> s.isNotEmpty() } }?.distinct().orEmpty()
        val text = m.str("text").orEmpty()
        if (to.isEmpty()) return fail(clientId, "There's nobody to send that to")
        if (text.isEmpty()) return fail(clientId, "That text is empty")
        // The system sends one message per recipient; a thread covering them all is what the Mac shows.
        val threadId = m.flexLong("threadId") ?: runCatching { repo.threadIdFor(to) }.getOrNull()
        try {
            val sms = smsManager()
            val parts = sms.divideMessage(text)
            tracker.begin(clientId, to.size * parts.size, threadId)
            timers.schedule({ tracker.expire(clientId)?.let(::report) }, SEND_TIMEOUT_S, TimeUnit.SECONDS)
            for ((r, address) in to.withIndex()) {
                val sent = ArrayList<PendingIntent>(parts.size)
                for (p in parts.indices) sent += sentIntent(clientId, r, p)
                sms.sendMultipartTextMessage(address, null, parts, sent, null)
            }
            Log.i(TAG, "sms.send queued recipients=${to.size} parts=${parts.size} len=${text.length}")
        } catch (e: Exception) {
            Log.w(TAG, "sms.send failed: ${e.javaClass.simpleName}")
            tracker.expire(clientId)
            fail(clientId, if (e is SecurityException) "Allow Mydroid to send texts on your phone" else "Your phone couldn't send that text", threadId)
        }
    }

    private fun sentIntent(clientId: String, recipient: Int, part: Int): PendingIntent {
        // Intent equality ignores extras, so the data Uri is what keeps each part's PendingIntent distinct.
        val i = Intent(ctx, SmsSentReceiver::class.java).setAction(SmsSentReceiver.ACTION)
            .setData(Uri.parse("mydroid-sms://sent/${Uri.encode(clientId)}/$recipient/$part"))
            .putExtra(SmsSentReceiver.EXTRA_CLIENT, clientId)
        return PendingIntent.getBroadcast(ctx, 0, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    /** From [SmsSentReceiver]: one part of a send finished. */
    fun onPartResult(clientId: String, resultCode: Int) {
        val ok = resultCode == Activity.RESULT_OK
        tracker.partResult(clientId, ok, if (ok) null else SmsErrors.describe(resultCode))?.let(::report)
    }

    private fun report(o: SendTracker.Outcome) {
        Log.i(TAG, "sms.sent ok=${o.ok}")
        reply(SmsWire.sent(o.clientId, o.ok, o.error, o.threadId))
    }

    // ------------------------------------------------------------------ sms.changed

    private val changes = ThreadChangeTracker()
    private val checker: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { Thread(it, "mydroid-sms-watch").apply { isDaemon = true } }
    @Volatile private var checkQueued = false
    private var observer: ContentObserver? = null

    @Synchronized
    fun setObserving(on: Boolean) {
        if (on == (observer != null)) return
        if (on) {
            val o = object : ContentObserver(main) {
                override fun onChange(selfChange: Boolean) = scheduleCheck(DEBOUNCE_MS)
            }
            runCatching { ctx.contentResolver.registerContentObserver(Telephony.MmsSms.CONTENT_URI, true, o) }.onSuccess { observer = o }
            changes.reset()
            scheduleCheck(0) // takes the baseline
            Log.i(TAG, "watching for changes")
        } else {
            observer?.let { ctx.contentResolver.unregisterContentObserver(it) }
            observer = null
            changes.reset()
            Log.i(TAG, "stopped watching")
        }
    }

    private fun scheduleCheck(delayMs: Long) {
        if (checkQueued && delayMs > 0) return // one pending check already covers every change before it runs
        checkQueued = true
        checker.schedule({ check() }, delayMs, TimeUnit.MILLISECONDS)
    }

    private fun check() {
        checkQueued = false
        if (observer == null || !readable()) return
        try {
            val r = changes.diff(repo.threadSnapshot(), System.currentTimeMillis())
            for (id in r.changed) reply(SmsWire.changed(id))
            if (r.changed.isNotEmpty()) Log.i(TAG, "sms.changed threads=${r.changed.size}")
            r.retryInMs?.let { scheduleCheck(it + 20) }
        } catch (e: Exception) {
            Log.w(TAG, "change check failed: ${e.javaClass.simpleName}")
        }
    }

    private companion object {
        const val DEBOUNCE_MS = 300L
        const val SEND_TIMEOUT_S = 90L
    }
}

/** Receives the per-part result of `SmsManager.sendMultipartTextMessage` (the sentIntents). */
class SmsSentReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION) return
        val id = intent.getStringExtra(EXTRA_CLIENT) ?: return
        context.manager().requests.sms.onPartResult(id, resultCode)
    }

    companion object {
        const val ACTION = "com.mydroid.android.SMS_SENT"
        const val EXTRA_CLIENT = "clientId"
    }
}

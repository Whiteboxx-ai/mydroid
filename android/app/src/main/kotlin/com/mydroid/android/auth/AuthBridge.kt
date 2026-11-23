package com.mydroid.android.auth

import android.app.KeyguardManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import com.mydroid.android.Channels
import com.mydroid.android.R
import com.mydroid.android.transfers.ActivityEntry
import com.mydroid.android.transfers.Direction
import com.mydroid.android.transfers.Kind
import com.mydroid.protocol.Message
import com.mydroid.protocol.auth.*
import java.util.UUID
import java.util.concurrent.Executors

private const val TAG = "MydroidAuth"

/**
 * The phone's side of PROTOCOL.md 14.2: list metadata, match a site, get approval, send one code. Secrets never leave this class
 * except as the single code the user approved. Logs counts and outcomes only: no code, secret, issuer, account or domain.
 */
class AuthBridge(
    private val ctx: Context,
    private val vault: AuthVault,
    private val prefs: AuthPrefs,
    private val send: (Message) -> Boolean,
    private val macName: () -> String,
    /** The Mac's Bluetooth presence says it is here (not merely that TCP is up). */
    private val macPresent: () -> Boolean,
    private val record: (ActivityEntry) -> Unit,
    private val onChanged: () -> Unit,
    /** PROTOCOL.md 14.4 (`auth.import`). */
    private val importer: AuthImporter,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private class Pending(val req: String, val entry: AuthEntry, val client: String, val notifId: Int, val timeout: Runnable)

    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "mydroid-auth").apply { isDaemon = true } }
    private val pending = LinkedHashMap<String, Pending>()
    private val km get() = ctx.getSystemService(KeyguardManager::class.java)

    fun handles(type: String) = type in AuthWire.TYPES

    /** Never blocks the socket reader. */
    fun dispatch(m: Message) { worker.execute { try { run(m) } catch (e: Exception) { Log.w(TAG, "${m.type} failed: ${e.javaClass.simpleName}") } } }

    private fun run(m: Message) {
        when (m.type) {
            AuthWire.LIST_GET -> {
                val req = AuthWire.req(m) ?: return
                val items = if (vault.health == AuthVault.Health.Ok) vault.all() else emptyList()
                send(AuthWire.list(req, items))
                Log.i(TAG, "auth.list items=${items.size}")
            }
            AuthWire.CODE_GET -> codeGet(m)
            AuthImportWire.IMPORT -> importer.start(m)
            AuthWire.DOMAIN_SET -> {
                val d = AuthWire.parseDomainSet(m) ?: return
                val e = vault.get(d.entryId) ?: return
                if (e.domains.none { Domains.normalize(it) == d.domain } && e.domains.size < MAX_DOMAINS) {
                    vault.setDomains(e.id, e.domains + d.domain); onChanged()
                }
                Log.i(TAG, "auth.domain.set ok")
            }
        }
    }

    // ---------------------------------------------------------------- auth.code.get

    private fun codeGet(m: Message) {
        val r = AuthWire.parseCodeGet(m) ?: return
        if (vault.health != AuthVault.Health.Ok) { send(AuthWire.error(r.req, AuthWire.LOCKED)); Log.i(TAG, "auth.code locked"); return }
        when (val hit = AuthWire.match(vault.all(), r)) {
            AuthMatch.None -> { send(AuthWire.error(r.req, AuthWire.NO_MATCH)); Log.i(TAG, "auth.code no_match") }
            is AuthMatch.Ambiguous -> { send(AuthWire.error(r.req, AuthWire.AMBIGUOUS, hit.choices)); Log.i(TAG, "auth.code ambiguous n=${hit.choices.size}") }
            is AuthMatch.One -> approveThenReply(r, hit.entry)
        }
    }

    /** Effective "last unlocked": right now when the screen is on and unlocked, else the last USER_PRESENT. */
    private fun lastUnlockedAt(): Long {
        val interactive = ctx.getSystemService(PowerManager::class.java).isInteractive
        return if (interactive && !km.isDeviceLocked) now() else prefs.lastUnlockedAt
    }

    private fun approveThenReply(r: CodeRequest, e: AuthEntry) {
        val decision = ApprovalPolicy.decide(prefs.approveMode, km.isDeviceLocked, lastUnlockedAt(), now(), prefs.autoMinutes, macPresent())
        if (decision == ApprovalPolicy.Decision.Auto) { Log.i(TAG, "auth.code auto-approved"); deliver(r.req, e); return }
        val nm = ctx.getSystemService(NotificationManager::class.java)
        val blocked = !nm.areNotificationsEnabled() || nm.getNotificationChannel(Channels.AUTH)?.importance == NotificationManager.IMPORTANCE_NONE
        synchronized(pending) {
            if (blocked || pending.size >= MAX_PENDING || pending.containsKey(r.req)) {
                // Nothing would show the user a prompt, or too many are open: answer now instead of leaving the Mac to wait 30 s.
                send(AuthWire.error(r.req, AuthWire.DENIED)); Log.i(TAG, "auth.code refused blocked=$blocked pending=${pending.size}"); return
            }
            val id = NOTIF_BASE + (counter++ % 900)
            val t = Runnable { expire(r.req) }
            pending[r.req] = Pending(r.req, e, r.client, id, t)
            main.postDelayed(t, TIMEOUT_MS)
            post(r.req, e, r.client, id)
        }
        Log.i(TAG, "auth.code asking")
    }

    private fun post(req: String, e: AuthEntry, client: String, id: Int) {
        val mac = macName().replaceFirstChar { it.uppercase() }
        val who = if (e.account.isBlank()) e.title else "${e.title} (${e.account})"
        fun action(kind: String, requestCode: Int) = PendingIntent.getBroadcast(
            ctx, requestCode, Intent(ctx, AuthActionReceiver::class.java).setAction(kind).putExtra(AuthActionReceiver.EXTRA_REQ, req).setPackage(ctx.packageName),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val approve = NotificationCompat.Action.Builder(0, "Approve", action(AuthActionReceiver.APPROVE, id * 2))
            .setAuthenticationRequired(true) // Android 12+: the system asks for the screen lock before this runs
            .build()
        val deny = NotificationCompat.Action.Builder(0, "Deny", action(AuthActionReceiver.DENY, id * 2 + 1)).build()
        val public = NotificationCompat.Builder(ctx, Channels.AUTH).setSmallIcon(R.drawable.ic_stat_mydroid)
            .setContentTitle("Code request").setContentText("Unlock to see details").build()
        // The text names the account and the Mac, never the code.
        val n = NotificationCompat.Builder(ctx, Channels.AUTH)
            .setSmallIcon(R.drawable.ic_stat_mydroid)
            .setContentTitle("Fill code for ${e.title}?")
            // The account is on the collapsed line too: it's how the user spots a wrong pick (e.g. Amazon vs AWS).
            .setContentText(listOf(e.account.ifBlank { null }, client).filterNotNull().joinToString(" · "))
            .setStyle(NotificationCompat.BigTextStyle().bigText("$who on $mac\nAsked by $client. Approve only if that was you."))
            .setPriority(NotificationCompat.PRIORITY_HIGH).setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE).setPublicVersion(public)
            .setOnlyAlertOnce(true).setAutoCancel(true).setTimeoutAfter(TIMEOUT_MS)
            .setDeleteIntent(action(AuthActionReceiver.DENY, id * 2 + 1))
            .addAction(approve).addAction(deny).build()
        runCatching { ctx.getSystemService(NotificationManager::class.java).notify(id, n) }
    }

    private fun expire(req: String) {
        val p = synchronized(pending) { pending.remove(req) } ?: return
        cancelNotification(p)
        worker.execute {
            send(AuthWire.error(req, AuthWire.TIMEOUT))
            logOutcome(p.entry, "Timed out")
            Log.i(TAG, "auth.code timeout")
        }
    }

    /** From the notification's Approve and Deny buttons. */
    fun resolve(req: String, approve: Boolean) {
        worker.execute {
            if (approve && km.isDeviceLocked) { Log.i(TAG, "auth.code approve ignored: device locked"); return@execute } // pre-Android 12 has no per-action unlock; stay pending
            val p = synchronized(pending) { pending.remove(req) } ?: return@execute
            main.removeCallbacks(p.timeout)
            cancelNotification(p)
            if (approve) { Log.i(TAG, "auth.code approved"); deliver(req, p.entry) }
            else { send(AuthWire.error(req, AuthWire.DENIED)); logOutcome(p.entry, "Denied"); Log.i(TAG, "auth.code denied") }
        }
    }

    /** The Mac went away: nobody is waiting for these any more. */
    fun onDisconnected() {
        val all = synchronized(pending) { pending.values.toList().also { pending.clear() } }
        all.forEach { main.removeCallbacks(it.timeout); cancelNotification(it) }
    }

    private fun cancelNotification(p: Pending) { runCatching { ctx.getSystemService(NotificationManager::class.java).cancel(p.notifId) } }

    private fun deliver(req: String, e: AuthEntry) {
        val reply = AuthWire.reply(e, now() / 1000)
        if (reply == null) { send(AuthWire.error(req, AuthWire.LOCKED)); return }
        val ok = send(AuthWire.code(req, e, reply.code, reply.validFor))
        if (ok) {
            if (e.type == OtpType.HOTP) { vault.advanceCounter(e.id); onChanged() }
            record(ActivityEntry(UUID.randomUUID().toString(), Direction.ToMac, Kind.Auth, "Code sent to ${macName().replaceFirstChar { it.uppercase() }} for ${e.title}", null, now()))
        }
        Log.i(TAG, "auth.code sent ok=$ok validFor=${reply.validFor}")
    }

    private fun logOutcome(e: AuthEntry, what: String) {
        record(ActivityEntry(UUID.randomUUID().toString(), Direction.ToMac, Kind.Auth, "Code request for ${e.title}", what, now(), ok = false))
    }

    companion object {
        const val TIMEOUT_MS = 30_000L
        private const val MAX_PENDING = 3
        private const val MAX_DOMAINS = 12
        private const val NOTIF_BASE = 4600
        private var counter = 0
    }
}

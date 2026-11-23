package com.mydroid.android.auth

import android.util.Log
import com.mydroid.android.transfers.ActivityEntry
import com.mydroid.android.transfers.Direction
import com.mydroid.android.transfers.Kind
import com.mydroid.protocol.Message
import com.mydroid.protocol.auth.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.util.UUID

/** What the review screen shows. Issuer and account only: the secrets stay inside [AuthImporter]. */
data class ImportReview(val req: String, val mac: String, val items: List<ImportItem>, val skipped: Int)

/** The result the review screen shows after Add. */
data class ImportDone(val added: Int, val skipped: Int, val needsBackup: Boolean)

/** How the user is told, away from the code that decides. The Android one posts a high-priority notification and opens the review screen. */
interface ImportSurface {
    /** Bring the review to the user. False when nothing could (notifications blocked): the import is then cancelled at once. */
    fun show(count: Int, mac: String): Boolean
    fun dismiss()
}

/**
 * PROTOCOL.md 14.4, the phone's side of `auth.import`: parse, skip duplicates, hold the secrets in memory while the user reviews them,
 * add them only after the user's Add (the screen asks for the biometric first), and answer with `auth.import.result`.
 * One import at a time. Nothing is written until Add; Cancel, the 2 minute timeout and a lost connection drop the secrets.
 * Logs counts only: never a URI, secret, issuer or account.
 */
class AuthImporter(
    private val vault: AuthVault,
    private val send: (Message) -> Boolean,
    private val macName: () -> String,
    private val surface: ImportSurface,
    private val record: (ActivityEntry) -> Unit,
    /** After accounts were added: nudge a backup if none exists, refresh the UI. Returns true when there is no backup yet. */
    private val onAdded: () -> Boolean,
    /** Runs [task] after the delay on any thread; returns a function that cancels it. */
    private val schedule: (delayMs: Long, task: () -> Unit) -> (() -> Unit),
    private val now: () -> Long = System::currentTimeMillis,
) {
    private class Pending(val req: String, val plan: ImportPlan, val cancelTimer: () -> Unit)

    private var pending: Pending? = null
    private val _review = MutableStateFlow<ImportReview?>(null)
    val review: StateFlow<ImportReview?> get() = _review

    private fun mac() = macName().replaceFirstChar { it.uppercase() }

    /** `auth.import` from the Mac. Never blocks the socket reader (called from the auth worker). */
    fun start(m: Message) {
        val r = AuthImportWire.parseRequest(m) ?: return
        val existing = vault.all() // loads the vault: `health` is only known after the first read
        if (vault.health != AuthVault.Health.Ok) { reply(r.req, false, 0, 0, AuthImportWire.LOCKED); Log.i(TAG, "auth.import locked"); return }
        val plan = AuthImportPlanner.plan(r.uris, existing)
        if (plan == null) { reply(r.req, false, 0, 0, AuthImportWire.INVALID); Log.i(TAG, "auth.import invalid uris=${r.uris.size}"); return }
        if (plan.fresh.isEmpty()) { reply(r.req, true, 0, plan.skipped, null); Log.i(TAG, "auth.import nothing new skipped=${plan.skipped}"); return }
        val busy: Boolean
        synchronized(this) {
            busy = pending != null
            if (!busy) {
                val cancelTimer = schedule(AuthImportWire.TIMEOUT_MS) { cancel(r.req) }
                pending = Pending(r.req, plan, cancelTimer)
                _review.value = ImportReview(r.req, mac(), plan.items, plan.skipped)
            }
        }
        if (busy) { reply(r.req, false, 0, 0, AuthImportWire.CANCELLED); Log.i(TAG, "auth.import refused: one is already open"); return }
        if (!surface.show(plan.fresh.size, mac())) {
            take(r.req)?.let { reply(it.req, false, 0, 0, AuthImportWire.CANCELLED) }
            Log.i(TAG, "auth.import cancelled: nothing could ask the user")
            return
        }
        Log.i(TAG, "auth.import asking n=${plan.fresh.size} skipped=${plan.skipped}")
    }

    /** Takes the pending import out of play (once): whoever gets it answers it. [req] null means whichever is open. */
    private fun take(req: String?): Pending? = synchronized(this) {
        val p = pending?.takeIf { req == null || it.req == req } ?: return null
        pending = null
        _review.value = null
        p.cancelTimer()
        p
    }

    /** The user pressed Add and passed the biometric. Null when nothing was waiting any more (cancelled, timed out). */
    fun confirm(req: String): ImportDone? {
        val p = take(req) ?: return null
        surface.dismiss()
        val added = try { vault.add(p.plan.fresh) } catch (e: Exception) {
            reply(p.req, false, 0, 0, AuthImportWire.LOCKED); Log.w(TAG, "auth.import couldn't write: ${e.javaClass.simpleName}"); return null
        }
        val skipped = p.plan.skipped + (p.plan.fresh.size - added)
        val needsBackup = onAdded()
        reply(p.req, true, added, skipped, null)
        record(ActivityEntry(UUID.randomUUID().toString(), Direction.FromMac, Kind.Auth, "Added ${if (added == 1) "1 account" else "$added accounts"} from ${mac()}", null, now()))
        Log.i(TAG, "auth.import added=$added skipped=$skipped")
        return ImportDone(added, skipped, needsBackup)
    }

    /** Cancel on the review screen or the notification, and the 2 minute timeout. */
    fun cancel(req: String? = null) { fail(req, AuthImportWire.CANCELLED) }

    /** Ends the open import with [error] (`cancelled`, or `locked` when the biometric locked the user out). */
    fun fail(req: String?, error: String) {
        val p = take(req) ?: return
        surface.dismiss()
        reply(p.req, false, 0, 0, error)
        record(ActivityEntry(UUID.randomUUID().toString(), Direction.FromMac, Kind.Auth, "Account import from ${mac()}", if (error == AuthImportWire.LOCKED) "Locked" else "Cancelled", now(), ok = false))
        Log.i(TAG, "auth.import $error")
    }

    /** The Mac went away: nobody is waiting for the answer, and the secrets should not linger. */
    fun onDisconnected() {
        take(null) ?: return
        surface.dismiss()
        Log.i(TAG, "auth.import dropped: disconnected")
    }

    private fun reply(req: String, ok: Boolean, added: Int, skipped: Int, error: String?) { send(AuthImportWire.result(req, ok, added, skipped, error)) }

    private companion object { const val TAG = "MydroidAuth" }
}

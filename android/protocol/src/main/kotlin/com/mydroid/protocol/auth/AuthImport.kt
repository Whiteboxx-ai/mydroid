package com.mydroid.protocol.auth

import com.mydroid.protocol.Message
import kotlinx.serialization.json.*

/** What the review screen may show about one account to be added: issuer and account, never the secret. */
data class ImportItem(val issuer: String, val account: String) {
    /** "Salesforce", or the account when there is no issuer. */
    val title: String get() = issuer.ifBlank { account.ifBlank { "Account" } }
    /** The account line, empty when it would only repeat the title. */
    val subtitle: String get() = if (issuer.isBlank()) "" else account

    companion object {
        /** Control characters out and a length cap: this text came from the Mac's camera, not from the user. */
        private fun clean(s: String) = s.filter { !it.isISOControl() }.trim().take(80)
        fun of(e: AuthEntry) = ImportItem(clean(e.issuer), clean(e.account))
    }
}

/**
 * The outcome of parsing an `auth.import` batch against the vault. [fresh] holds secrets: keep it in memory only until the user
 * adds or cancels, then drop it. `toString` says counts and nothing else, so a stray log line can't leak anything.
 */
class ImportPlan(val fresh: List<AuthEntry>, val skipped: Int) {
    val items: List<ImportItem> get() = fresh.map(ImportItem::of)
    override fun toString() = "ImportPlan(fresh=${fresh.size}, skipped=$skipped)"
}

/** PROTOCOL.md 14.4: M→P `auth.import {req, uris}` and the phone's `auth.import.result`. */
object AuthImportWire {
    const val IMPORT = "auth.import"
    const val RESULT = "auth.import.result"

    const val CANCELLED = "cancelled"
    const val LOCKED = "locked"
    const val INVALID = "invalid"

    /** The user has this long to review before the import is dropped as `cancelled`. */
    const val TIMEOUT_MS = 120_000L

    /** Limits so a bad or hostile Mac can't make the phone chew on gigabytes: far above any real export. */
    const val MAX_URIS = 64
    const val MAX_URI_CHARS = 20_000
    const val MAX_ENTRIES = 500

    /** [uris] are secrets: they never appear in `toString`. */
    class Request(val req: String, val uris: List<String>) {
        override fun toString() = "Request(uris=${uris.size})"
    }

    /** Null without a `req` (nobody to answer). A missing or odd `uris` is an empty list, which parses to `invalid`. */
    fun parseRequest(m: Message): Request? {
        val req = (m.header["req"] as? JsonPrimitive)?.content?.takeIf { it.isNotEmpty() } ?: return null
        val uris = m.arr("uris").orEmpty().take(MAX_URIS).mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
        return Request(req, uris)
    }

    fun result(req: String, ok: Boolean, added: Int, skipped: Int, error: String? = null): Message = Message.of(RESULT) {
        put("req", req); put("ok", ok); put("added", added); put("skipped", skipped)
        if (error != null) put("error", error)
    }
}

object AuthImportPlanner {
    /**
     * Reads every URI (`otpauth://` and `otpauth-migration://`, several batches allowed) and drops what the vault already has,
     * and repeats inside the batch. Null when nothing at all could be read: the Mac gets `invalid`.
     * [ImportPlan.skipped] counts duplicates, entries Google's export held that couldn't be read, and URIs that weren't usable.
     */
    fun plan(uris: List<String>, existing: List<AuthEntry>): ImportPlan? {
        val parsed = ArrayList<AuthEntry>()
        var unreadable = 0
        for (raw in uris.take(AuthImportWire.MAX_URIS)) {
            if (raw.length > AuthImportWire.MAX_URI_CHARS) { unreadable++; continue }
            when {
                OtpAuthUri.isOtpAuth(raw) -> OtpAuthUri.parse(raw)?.let { parsed += it } ?: run { unreadable++ }
                Migration.isMigration(raw) -> {
                    val p = Migration.parse(raw)
                    if (p == null) unreadable++ else { parsed += p.entries; unreadable += p.skipped }
                }
                else -> unreadable++
            }
        }
        if (parsed.isEmpty()) return null
        val capped = parsed.take(AuthImportWire.MAX_ENTRIES)
        val fresh = AuthEntries.newOnly(existing, capped)
        return ImportPlan(fresh, skipped = (capped.size - fresh.size) + (parsed.size - capped.size) + unreadable)
    }
}

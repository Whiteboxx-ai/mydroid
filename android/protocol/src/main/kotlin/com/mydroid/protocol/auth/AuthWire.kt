package com.mydroid.protocol.auth

import com.mydroid.protocol.Message
import kotlinx.serialization.json.*

/** What the Mac asked for in `auth.code.get`. */
data class CodeRequest(val req: String, val domains: List<String>, val account: String?, val entryId: String?, val client: String)

data class Choice(val id: String, val issuer: String, val account: String)

/** How a code request resolves against the vault, before any approval. */
sealed class AuthMatch {
    class One(val entry: AuthEntry) : AuthMatch()
    class Ambiguous(val choices: List<Choice>) : AuthMatch()
    object None : AuthMatch()
}

/** The §14.2 messages and §14.2 phone policy, without Android in it. Nothing here logs; codes and secrets stay out of any `toString`. */
object AuthWire {
    const val LIST_GET = "auth.list.get"
    const val CODE_GET = "auth.code.get"
    const val DOMAIN_SET = "auth.domain.set"
    val TYPES = setOf(LIST_GET, CODE_GET, DOMAIN_SET, AuthImportWire.IMPORT)

    const val DENIED = "denied"
    const val TIMEOUT = "timeout"
    const val NO_MATCH = "no_match"
    const val AMBIGUOUS = "ambiguous"
    const val LOCKED = "locked"

    /** Seconds left below which the next period's code is sent instead. */
    const val MIN_VALID_SECONDS = 5

    // ---- Mac to phone

    /** `req` is a string on the wire; a number is tolerated. */
    fun req(m: Message): String? = (m.header["req"] as? JsonPrimitive)?.content?.takeIf { it.isNotEmpty() }

    fun parseCodeGet(m: Message): CodeRequest? {
        val req = req(m) ?: return null
        val domains = Domains.split(m.str("domain").orEmpty() + " " + m.str("host").orEmpty())
        val entryId = m.str("entryId")?.takeIf { it.isNotBlank() }
        if (domains.isEmpty() && entryId == null) return null
        return CodeRequest(req, domains, m.str("account")?.trim()?.takeIf { it.isNotEmpty() }, entryId, (m.str("client") ?: "").take(60).ifBlank { "a browser" })
    }

    class DomainSet(val entryId: String, val domain: String)

    fun parseDomainSet(m: Message): DomainSet? {
        val id = m.str("entryId") ?: return null
        val d = Domains.normalize(m.str("domain") ?: return null)
        return if (Domains.isPlausibleHost(d)) DomainSet(id, d) else null
    }

    // ---- phone to Mac

    /** Metadata only: never a secret, never a code. */
    fun list(req: String, entries: List<AuthEntry>): Message = Message.of("auth.list") {
        put("req", req)
        put("items", buildJsonArray {
            for (e in entries) add(buildJsonObject {
                put("id", e.id); put("issuer", e.issuer); put("account", e.account)
                put("domains", JsonArray(e.domains.map { JsonPrimitive(it) })); put("digits", e.digits)
            })
        })
    }

    fun code(req: String, entry: AuthEntry, code: String, validFor: Int): Message = Message.of("auth.code") {
        put("req", req); put("ok", true); put("code", code); put("validFor", validFor); put("entryId", entry.id)
    }

    fun error(req: String, error: String, choices: List<Choice> = emptyList()): Message = Message.of("auth.code") {
        put("req", req); put("ok", false); put("error", error)
        if (choices.isNotEmpty()) put("choices", buildJsonArray {
            for (c in choices) add(buildJsonObject { put("id", c.id); put("issuer", c.issuer); put("account", c.account) })
        })
    }

    // ---- policy

    /**
     * Step 1 of the phone policy: entries whose `domains` contain a requested host (subdomains allowed), narrowed by `account`.
     * An `entryId` the user already picked on the Mac wins outright when it exists.
     */
    fun match(entries: List<AuthEntry>, r: CodeRequest): AuthMatch {
        r.entryId?.let { id -> return entries.firstOrNull { it.id == id }?.let { AuthMatch.One(it) } ?: AuthMatch.None }
        // Most specific wins: on signin.aws.amazon.com an entry for aws.amazon.com beats one for amazon.com.
        // Specificity = the longest entry domain that matches any requested host (labels, then length).
        fun specificity(e: AuthEntry): Int = e.domains.maxOfOrNull { d ->
            if (r.domains.any { h -> Domains.matches(h, d) }) Domains.normalize(d).let { it.count { c -> c == '.' } * 1000 + it.length } else -1
        } ?: -1
        val scored = entries.map { it to specificity(it) }.filter { it.second >= 0 }
        if (scored.isEmpty()) return AuthMatch.None
        val best = scored.maxOf { it.second }
        var c = scored.filter { it.second == best }.map { it.first }
        val acct = r.account
        if (acct != null && c.size > 1) {
            val narrowed = c.filter { accountMatches(acct, it.account) }
            if (narrowed.isNotEmpty()) c = narrowed
        }
        return if (c.size == 1) AuthMatch.One(c[0]) else AuthMatch.Ambiguous(c.map { Choice(it.id, it.issuer, it.account) })
    }

    /** "me@work.com" matches "me@work.com", "ME@work.com", and the bare user name "me". */
    fun accountMatches(typed: String, stored: String): Boolean {
        val a = typed.trim().lowercase(); val b = stored.trim().lowercase()
        if (a.isEmpty() || b.isEmpty()) return false
        return a == b || a == b.substringBefore('@') || b == a.substringBefore('@')
    }

    /** The code to send now and how many seconds it stays valid. Under [MIN_VALID_SECONDS] left, the next period's code goes out instead. */
    class Reply(val code: String, val validFor: Int)

    fun reply(e: AuthEntry, unixSeconds: Long): Reply? {
        if (e.type == OtpType.HOTP) return e.code(unixSeconds)?.let { Reply(it, e.period.coerceAtLeast(30)) }
        val left = Otp.secondsRemaining(unixSeconds, e.period)
        val at = if (left < MIN_VALID_SECONDS) unixSeconds + left else unixSeconds
        val code = e.code(at) ?: return null
        return Reply(code, Otp.secondsRemaining(at, e.period))
    }
}

/** "Approve automatically" (off by default): only while the phone was unlocked recently and the Mac is here. Anything else asks. */
object ApprovalPolicy {
    enum class Mode { Ask, Auto }
    enum class Decision { Auto, Ask }

    fun decide(
        mode: Mode, deviceLocked: Boolean, lastUnlockedAtMs: Long, nowMs: Long, windowMinutes: Int, macPresent: Boolean,
    ): Decision {
        if (mode != Mode.Auto) return Decision.Ask
        if (deviceLocked) return Decision.Ask
        if (!macPresent) return Decision.Ask
        if (lastUnlockedAtMs <= 0 || nowMs < lastUnlockedAtMs) return Decision.Ask
        return if (nowMs - lastUnlockedAtMs <= windowMinutes.coerceAtLeast(1) * 60_000L) Decision.Auto else Decision.Ask
    }
}

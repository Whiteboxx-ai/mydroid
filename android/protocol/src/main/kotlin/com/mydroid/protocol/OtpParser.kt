package com.mydroid.protocol

/** A one-time code found in a notification (PROTOCOL.md §5.1 `otp`). */
data class Otp(val code: String, val source: String)

/**
 * Pulls a one-time code out of notification text. Pure Kotlin so it can be unit-tested on the JVM.
 *
 * Approach: a text must contain an OTP-ish keyword (otp, code, verification, pin, ...). Then every
 * digit run (optionally split by single spaces or dashes: "12 34 56", "482-196") and every
 * upper-case alphanumeric token ("AB12CD") is a candidate. Candidates that are amounts, dates, times,
 * phone numbers, order or account numbers are dropped; the survivor closest to a keyword wins.
 * Returns null rather than guess.
 */
object OtpParser {
    private val STRONG = listOf(
        "otp", "ओटीपी", "one-time", "one time", "onetime", "verification", "verify", "passcode", "pass code",
        "2fa", "security code", "authentication", "pin",
    )
    private val WEAK = listOf("code", "login", "log in", "log-in", "sign in", "sign-in", "signin", "password")

    private fun kwRegex(words: List<String>) =
        Regex("(?<![\\p{L}\\p{N}])(?:" + words.joinToString("|") { Regex.escape(it) } + ")s?(?![\\p{L}\\p{N}])")

    private val strongRx = kwRegex(STRONG)
    private val weakRx = kwRegex(WEAK)
    private val promoRx = Regex("promo|coupon|discount|voucher|cashback|\\boffer|% ?off|\\bsave\\b|\\bsale\\b|referral")
    private val codeIsRx = Regex("(?<![\\p{L}\\p{N}])code\\s*(?:is|:|-)")

    // Optional "G-" style prefix, then digits with optional single space/dash separators.
    private val runRx = Regex("(?<![\\p{L}\\p{N}_])([A-Za-z]{1,2}-)?(\\d+(?:[ -]\\d+)*)(?![\\p{L}\\p{N}_])")
    private val tokenRx = Regex("(?<![\\p{L}\\p{N}_])[A-Za-z0-9]{5,8}(?![\\p{L}\\p{N}_])")
    private val tokenBefore = Regex("([^\\s]+)\\s*$")
    private val nextWordRx = Regex("^\\s*([A-Za-z%/]+)")

    private val badPrecedingWords = setOf(
        "a/c", "ac", "acct", "account", "acc", "no", "number", "num", "ref", "reference", "txn", "id", "order",
        "invoice", "ending", "ends", "card", "mobile", "phone", "ph", "tel", "call", "rs", "inr", "usd", "amount",
        "amt", "balance", "bal", "dated", "date", "ticket", "awb", "tracking", "flight", "pnr",
    )
    private val badFollowingWords = setOf(
        "min", "mins", "minute", "minutes", "sec", "secs", "second", "seconds", "hr", "hrs", "hour", "hours", "day",
        "days", "point", "points", "pts", "rs", "inr", "rupees", "usd", "%", "kg", "km", "gb", "mb", "am", "pm",
    )

    private class Cand(val code: String, val start: Int, val end: Int)

    fun parse(text: String?, source: String): Otp? {
        if (text.isNullOrBlank() || text.length > 2000) return null
        val s = text.replace(' ', ' ').replace(' ', ' ')
        val low = s.lowercase()
        val strong = strongRx.findAll(low).map { it.range }.toList()
        val weak = weakRx.findAll(low).map { it.range }.toList()
        if (strong.isEmpty() && weak.isEmpty()) return null
        if (strong.isEmpty() && promoRx.containsMatchIn(low)) return null
        val kws = strong + weak

        val cands = ArrayList<Cand>()
        for (m in runRx.findAll(s)) numericCandidate(s, m)?.let { cands += it }
        if (strong.isNotEmpty() || codeIsRx.containsMatchIn(low)) {
            for (m in tokenRx.findAll(s)) alnumCandidate(s, m)?.let { cands += it }
        }
        if (cands.isEmpty()) return null

        var best: Cand? = null
        var bestDist = Int.MAX_VALUE
        for (c in cands) {
            var d = Int.MAX_VALUE
            for (k in kws) {
                val dist = if (c.start >= k.last) c.start - k.last - 1 else maxOf(0, k.first - c.end)
                if (dist < d) d = dist
            }
            if (d < bestDist) { bestDist = d; best = c }
        }
        if (best == null || bestDist > 100) return null
        return Otp(best.code, source)
    }

    private fun numericCandidate(s: String, m: MatchResult): Cand? {
        val run = m.groups[2]!!
        val runEnd = run.range.last + 1
        // What immediately surrounds the run.
        val startOfToken = m.range.first
        val b = if (startOfToken > 0) s[startOfToken - 1] else ' '
        if (b in "+/#₹$€£@*" ) return null
        if (b in ".,:" && startOfToken >= 2 && s[startOfToken - 2].isDigit()) return null
        val a = if (runEnd < s.length) s[runEnd] else ' '
        if (a in "%/@") return null
        if (a in ".,:" && runEnd + 1 < s.length && s[runEnd + 1].isDigit()) return null
        // "Rs.5000", "Rs 5000", "No.123456", "a/c 1234": judged on the word before.
        val pre = s.substring(0, startOfToken)
        val w = tokenBefore.find(pre)?.groupValues?.get(1)?.lowercase()?.trimEnd(':', '.', ',', '-', '#')
        if (w != null && w in badPrecedingWords) return null

        val groups = run.value.split(' ', '-').filter { it.isNotEmpty() }
        val seps = run.value.filter { it == ' ' || it == '-' }
        val digits: String
        if (groups.size == 1) {
            digits = groups[0]
        } else {
            val sizes = groups.map { it.length }
            val total = sizes.sum()
            val dash = seps.contains('-')
            val equal = sizes.all { it == sizes[0] }
            val ok = when {
                dash -> sizes.size == 2 && equal && (sizes[0] == 3 || sizes[0] == 4)
                else -> equal && ((sizes.size == 2 && sizes[0] in 2..4) || (sizes.size in 3..4 && sizes[0] == 2))
            }
            if (ok) {
                digits = groups.joinToString("")
            } else if (!dash && total <= 8 && groups.drop(1).all { it.length <= 2 } && groups[0].length in 4..8) {
                // "482196 10 mins": the code is the first group, the rest is something else.
                val firstEnd = run.range.first + groups[0].length
                return if (followedByUnit(s, firstEnd)) null else Cand(groups[0], run.range.first, firstEnd)
            } else {
                return null
            }
        }
        if (digits.length !in 4..8 || followedByUnit(s, runEnd)) return null
        return Cand(digits, startOfToken, runEnd)
    }

    /** "10 mins", "5000 points": the number is a quantity, not a code. */
    private fun followedByUnit(s: String, end: Int): Boolean =
        nextWordRx.find(s.substring(end))?.groupValues?.get(1)?.lowercase()?.let { it in badFollowingWords } == true

    private fun alnumCandidate(s: String, m: MatchResult): Cand? {
        val t = m.value
        if (!t.all { it in 'A'..'Z' || it in '0'..'9' }) return null
        if (t.none { it.isDigit() } || t.none { it in 'A'..'Z' }) return null
        if (t.count { it.isDigit() } < 2) return null
        // Masked account or card endings: XX1234, XXXX1234.
        if (Regex("^X{1,}\\d+$").matches(t)) return null
        val pre = s.substring(0, m.range.first)
        val w = tokenBefore.find(pre)?.groupValues?.get(1)?.lowercase()?.trimEnd(':', '.', ',', '-', '#')
        if (w != null && w in badPrecedingWords) return null
        // "OD1234567", "TXN123456"-style ids are 8+ chars with a long digit tail; real alnum codes mix both.
        if (Regex("^[A-Z]{1,3}\\d{6,}$").matches(t) && t.length >= 8) return null
        return Cand(t, m.range.first, m.range.last + 1)
    }
}

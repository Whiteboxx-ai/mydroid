package com.mydroid.protocol

/** One PDU part as delivered by `SMS_RECEIVED` (already decoded to text). */
data class SmsPart(val address: String, val body: String)

/** An SMS we saw arrive. [consumed] flips once a notification (real or synthetic) carries it to the Mac. */
class SmsEntry(
    val address: String,
    val body: String,
    val at: Long,
    val otp: Otp?,
    /** Other names the notification may use for this sender, e.g. the contact name. */
    val aliases: List<String> = emptyList(),
) {
    @Volatile var consumed = false
}

object SmsAssembler {
    /** Concatenates consecutive parts from the same sender into one message (multipart SMS arrive as several PDUs). */
    fun assemble(parts: List<SmsPart>): List<SmsPart> {
        val out = ArrayList<SmsPart>()
        for (p in parts) {
            val last = out.lastOrNull()
            if (last != null && last.address == p.address) out[out.size - 1] = SmsPart(last.address, last.body + p.body) else out += p
        }
        return out
    }
}

/** Recovering SMS text that Android 15+ hid from notification listeners. Never log what is stored here. */
object Redaction {
    const val ENGLISH = "Sensitive notification content hidden"

    fun isRedacted(text: CharSequence?, markers: Collection<String>): Boolean {
        val t = text?.toString()?.trim() ?: return false
        if (t.isEmpty()) return false
        return markers.any { it.isNotBlank() && t.equals(it.trim(), ignoreCase = true) } || t.equals(ENGLISH, ignoreCase = true)
    }
}

/** Short-lived memory of recent SMS, matched against notification titles. */
class SmsCache(private val ttlMs: Long = 120_000, private val maxEntries: Int = 20) {
    private val items = ArrayList<SmsEntry>()

    @Synchronized
    fun add(e: SmsEntry) {
        prune(e.at)
        items += e
        while (items.size > maxEntries) items.removeAt(0)
    }

    private fun prune(now: Long) { items.removeAll { now - it.at > ttlMs } }

    /**
     * Newest SMS within [windowMs] whose sender matches one of [titles] (number, sender id or contact name).
     * With [lenient], a lone unconsumed recent SMS matches even if no name does (the notification came from
     * the SMS app itself, so it is almost certainly that message).
     */
    @Synchronized
    fun find(titles: List<String>, now: Long, windowMs: Long = 60_000, lenient: Boolean = false): SmsEntry? {
        prune(now)
        val recent = items.filter { now - it.at <= windowMs }.sortedByDescending { it.at }
        recent.firstOrNull { e -> titles.any { t -> senderMatches(t, e) } }?.let { return it }
        if (lenient) recent.filter { !it.consumed }.singleOrNull()?.let { return it }
        return null
    }

    @Synchronized fun size(): Int = items.size

    companion object {
        private fun digits(s: String) = s.filter { it.isDigit() }
        private fun key(s: String): String {
            val t = s.trim()
            // Indian/EU sender ids look like "VM-HDFCBK": drop the 2-char route prefix.
            val stripped = if (Regex("^[A-Za-z0-9]{2}-[A-Za-z0-9 ]{3,}$").matches(t)) t.substring(3) else t
            return stripped.lowercase().filter { it.isLetterOrDigit() }
        }

        fun senderMatches(title: String, e: SmsEntry): Boolean {
            if (title.isBlank()) return false
            return (listOf(e.address) + e.aliases).any { c -> nameMatches(title, c) }
        }

        fun nameMatches(title: String, candidate: String): Boolean {
            val td = digits(title); val cd = digits(candidate)
            if (td.length >= 7 && cd.length >= 7 && title.none { it.isLetter() } && candidate.none { it.isLetter() }) {
                return td.takeLast(10) == cd.takeLast(10)
            }
            val a = key(title); val b = key(candidate)
            if (a.length < 3 || b.length < 3) return false
            if (a == b || a.contains(b) || b.contains(a)) return true
            return a.commonPrefixWith(b).length >= 4 // "HDFCBK" vs "HDFC Bank"
        }
    }
}

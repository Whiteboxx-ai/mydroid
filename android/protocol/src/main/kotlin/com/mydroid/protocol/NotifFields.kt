package com.mydroid.protocol

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * The optional `notif.posted` fields of PROTOCOL.md 13.1 (`person`, `links`, `media`) and the careful, pure
 * logic behind them. Everything here can be wrong in subtle ways and has JVM tests; the Android side only
 * feeds it strings. Nothing here logs.
 */
object NotifFields {
    fun person(name: String, phone: String?): JsonObject = buildJsonObject {
        put("name", name)
        if (phone != null) put("phone", phone)
    }

    fun links(urls: List<String>): JsonArray = JsonArray(urls.map { JsonPrimitive(it) })

    /** `media`: title and artist always (possibly empty), album and mediaId only when known. */
    fun media(title: String, artist: String, album: String?, mediaId: String?): JsonObject = buildJsonObject {
        put("title", title); put("artist", artist)
        if (!album.isNullOrBlank()) put("album", album)
        if (mediaId != null) put("mediaId", mediaId)
    }
}

/** http(s) URLs found in notification text. */
object NotifLinks {
    const val MAX = 3
    private const val MAX_LEN = 2048

    private val URL = Regex("""(?i)(?<![\w@.])(?:https?://|www\.)[^\s<>"'` ]+""")
    private const val TRAILING = ".,;:!?'\"…»”’"

    /**
     * Up to [MAX] distinct http(s) URLs, in order of appearance across [texts] (earlier texts first). `www.` links get
     * `https://`. Trailing punctuation and an unbalanced closing bracket are not part of the link; anything over
     * 2048 chars, without a host or with credentials is dropped.
     */
    fun extract(texts: List<CharSequence?>): List<String> {
        val out = LinkedHashSet<String>()
        for (t in texts) {
            if (t.isNullOrEmpty()) continue
            for (m in URL.findAll(t)) {
                val u = clean(m.value) ?: continue
                out.add(u)
                if (out.size >= MAX) return out.toList()
            }
        }
        return out.toList()
    }

    private fun clean(raw: String): String? {
        var s = raw
        while (s.isNotEmpty()) {
            val c = s.last()
            val strip = c in TRAILING ||
                (c == ')' && s.count { it == '(' } < s.count { it == ')' }) ||
                (c == ']' && s.count { it == '[' } < s.count { it == ']' }) ||
                (c == '}' && s.count { it == '{' } < s.count { it == '}' })
            if (!strip) break
            s = s.dropLast(1)
        }
        if (s.length > MAX_LEN) return null
        val lower = s.lowercase()
        val withScheme = when {
            lower.startsWith("https://") -> "https://" + s.substring(8)
            lower.startsWith("http://") -> "http://" + s.substring(7)
            lower.startsWith("www.") -> "https://$s"
            else -> return null
        }
        val rest = withScheme.substringAfter("://")
        val authority = rest.takeWhile { it != '/' && it != '?' && it != '#' }
        if (authority.contains('@')) return null // user:pass@host is never worth offering
        val host = authority.substringBefore(':')
        val ok = host.any { it.isLetterOrDigit() } && (host.contains('.') || host.equals("localhost", true)) &&
            !host.startsWith('.') && !host.endsWith('.')
        return if (ok) withScheme else null
    }
}

/** `tel:` URIs from `Person.uri`. */
object TelUri {
    /** The number part of `tel:+91%2098765%2043210;ext=1`, or null when [uri] isn't a tel URI. */
    fun number(uri: String?): String? {
        val u = uri?.trim() ?: return null
        if (!u.startsWith("tel:", ignoreCase = true)) return null
        val body = u.substring(4).substringBefore(';').substringBefore('?').substringBefore('#')
        val decoded = percentDecode(body).trim()
        return decoded.takeIf { it.isNotEmpty() }
    }

    private fun percentDecode(s: String): String {
        if (!s.contains('%')) return s
        val b = java.io.ByteArrayOutputStream()
        var i = 0
        while (i < s.length) {
            val c = s[i]
            if (c == '%' && i + 2 < s.length) {
                val v = s.substring(i + 1, i + 3).toIntOrNull(16)
                if (v != null) { b.write(v); i += 3; continue }
            }
            b.write(c.toString().toByteArray(Charsets.UTF_8)); i++
        }
        return String(b.toByteArray(), Charsets.UTF_8)
    }
}

/**
 * A small, careful E.164 normaliser (libphonenumber is a large dependency for one lookup). It answers only when it
 * is sure: international numbers need a plausible country code and total length; national numbers need a known
 * region, an exact national length for that region, and the region's trunk prefix stripped. Anything else, any
 * letters (short codes, sender ids) and any doubt gives null.
 */
object PhoneE164 {
    private class Region(val cc: String, val trunk: String, val min: Int, val max: Int)

    private val regions: Map<String, Region> = mapOf(
        "US" to Region("1", "1", 10, 10), "CA" to Region("1", "1", 10, 10),
        "GB" to Region("44", "0", 9, 10), "IE" to Region("353", "0", 7, 9),
        "IN" to Region("91", "0", 10, 10), "PK" to Region("92", "0", 10, 10), "BD" to Region("880", "0", 10, 10),
        "LK" to Region("94", "0", 9, 9), "NP" to Region("977", "0", 10, 10),
        "AU" to Region("61", "0", 9, 9), "NZ" to Region("64", "0", 8, 10),
        "DE" to Region("49", "0", 10, 11), "FR" to Region("33", "0", 9, 9), "ES" to Region("34", "", 9, 9),
        "IT" to Region("39", "", 9, 11), "NL" to Region("31", "0", 9, 9), "BE" to Region("32", "0", 8, 9),
        "CH" to Region("41", "0", 9, 9), "AT" to Region("43", "0", 10, 12), "SE" to Region("46", "0", 7, 9),
        "NO" to Region("47", "", 8, 8), "DK" to Region("45", "", 8, 8), "FI" to Region("358", "0", 8, 10),
        "PL" to Region("48", "", 9, 9), "PT" to Region("351", "", 9, 9),
        "BR" to Region("55", "0", 10, 11), "MX" to Region("52", "", 10, 10),
        "JP" to Region("81", "0", 9, 10), "KR" to Region("82", "0", 9, 10), "CN" to Region("86", "0", 11, 11),
        "SG" to Region("65", "", 8, 8), "HK" to Region("852", "", 8, 8),
        "AE" to Region("971", "0", 8, 9), "SA" to Region("966", "0", 8, 9), "IL" to Region("972", "0", 8, 9),
        "TR" to Region("90", "0", 10, 10), "RU" to Region("7", "8", 10, 10), "KZ" to Region("7", "8", 10, 10),
        "ID" to Region("62", "0", 9, 12), "MY" to Region("60", "0", 9, 10), "TH" to Region("66", "0", 8, 9),
        "PH" to Region("63", "0", 10, 10), "VN" to Region("84", "0", 9, 10),
        "ZA" to Region("27", "0", 9, 9), "NG" to Region("234", "0", 10, 10), "KE" to Region("254", "0", 9, 9),
        "EG" to Region("20", "0", 10, 10),
    )

    private val twoDigit = setOf(
        "20", "27", "30", "31", "32", "33", "34", "36", "39", "40", "41", "43", "44", "45", "46", "47", "48", "49",
        "51", "52", "53", "54", "55", "56", "57", "58", "60", "61", "62", "63", "64", "65", "66",
        "81", "82", "84", "86", "90", "91", "92", "93", "94", "95", "98",
    )
    private val threeDigitFirstTwo = setOf(
        "21", "22", "23", "24", "25", "26", "29", "35", "37", "38", "42", "50", "59", "67", "68", "69",
        "85", "87", "88", "96", "97", "99",
    )

    /** Length of the country calling code at the start of [digits], or 0 when it isn't one. */
    private fun ccLength(digits: String): Int = when {
        digits.isEmpty() -> 0
        digits[0] == '1' || digits[0] == '7' -> 1
        digits.length >= 2 && digits.substring(0, 2) in twoDigit -> 2
        digits.length >= 3 && digits.substring(0, 2) in threeDigitFirstTwo -> 3
        else -> 0
    }

    /** [raw] as `+<digits>`, or null when not sure. [region] is an ISO 3166 alpha-2 code (any case), or null/blank. */
    fun normalize(raw: String?, region: String?): String? {
        val s = raw?.trim() ?: return null
        if (s.isEmpty() || s.length > 40) return null
        // Drop an extension; anything else that isn't phone punctuation means this isn't a plain number.
        val main = s.split(Regex("""(?i)\s*(?:;ext=|\bext\.?|\bx|#)""")).first().trim()
        if (main.isEmpty() || main.any { !(it.isDigit() || it in "+ -.()/ ") }) return null
        if (main.lastIndexOf('+') > 0) return null
        val digits = main.filter { it.isDigit() }
        if (digits.isEmpty()) return null
        if (main.startsWith("+")) return international(digits)
        val r = region?.trim()?.uppercase()?.takeIf { it.length == 2 }?.let { regions[it] }
        if (digits.startsWith("00") && r?.cc != "1") return international(digits.drop(2))
        if (r == null) return null
        if (r.cc == "1" && digits.startsWith("011")) return international(digits.drop(3))
        if (r.trunk.isNotEmpty() && digits.startsWith(r.trunk)) {
            val n = digits.drop(r.trunk.length)
            if (nationalOk(r, n)) return "+${r.cc}$n"
        }
        if (nationalOk(r, digits)) return "+${r.cc}$digits"
        // "919876543210": already carries the country code, and can't be read as a national number.
        if (digits.startsWith(r.cc)) {
            val n = digits.drop(r.cc.length)
            if (digits.length > r.max && nationalOk(r, n)) return "+${r.cc}$n"
        }
        return null
    }

    private fun nationalOk(r: Region, n: String): Boolean {
        if (n.length !in r.min..r.max) return false
        if (n[0] == '0' && (r.trunk.isNotEmpty() || r.cc != "39")) return false
        if (r.cc == "1" && (n[0] < '2' || n[0] > '9')) return false
        return true
    }

    private fun international(digits: String): String? {
        if (digits.length !in 8..15 || digits[0] == '0') return null
        val cl = ccLength(digits)
        if (cl == 0) return null
        val cc = digits.substring(0, cl)
        val national = digits.substring(cl)
        if (cc == "1" && digits.length != 11) return null
        val known = regions.values.filter { it.cc == cc }
        if (known.isNotEmpty() && known.none { national.length in it.min..it.max }) return null
        if (digits.all { it == digits[0] }) return null
        return "+$digits"
    }

    /** Looks like a bare phone number (an SMS sender shown by number): digits and phone punctuation only, 7+ digits. */
    fun looksLikeNumber(s: String?): Boolean {
        val t = s?.trim() ?: return false
        if (t.length > 25 || t.any { !(it.isDigit() || it in "+ -.() ") }) return false
        return t.count { it.isDigit() } >= 7
    }
}

/** What a media session may say about the track's identity, and what is safe to forward. */
object MediaIds {
    private val SPOTIFY = Regex("""spotify:(track|episode):[A-Za-z0-9]{22}""")
    private const val MAX_URL = 2048

    /** [candidate] when it looks like `spotify:track:…`, `spotify:episode:…` or an http(s) URL; otherwise null. */
    fun filter(candidate: String?): String? {
        val c = candidate?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        if (SPOTIFY.matches(c)) return c
        if (c.length <= MAX_URL && (c.startsWith("http://", true) || c.startsWith("https://", true)) &&
            c.none { it.isWhitespace() || it.isISOControl() } &&
            c.substringAfter("://").takeWhile { it != '/' && it != '?' && it != '#' }.let { a -> !a.contains('@') && a.any { it.isLetterOrDigit() } }
        ) return c
        return null
    }

    /** The label for what kind of identifier [candidate] is. A fixed vocabulary, so it can be logged. */
    fun scheme(candidate: String?): String {
        val c = candidate?.trim()?.takeIf { it.isNotEmpty() } ?: return "none"
        return when {
            SPOTIFY.matches(c) -> "spotify:" + c.split(':')[1]
            c.startsWith("http://", true) || c.startsWith("https://", true) -> "http"
            else -> "other"
        }
    }

    /** Which metadata field a media id came from. */
    enum class Field(val label: String) { MEDIA_ID("MEDIA_ID"), MEDIA_URI("MEDIA_URI"), NONE("none") }

    /** The id to forward (from MEDIA_ID, else MEDIA_URI, whichever passes [filter] first) and the diagnostic summary. */
    class Pick(val id: String?, val scheme: String, val field: Field) {
        /** `spotify-mediaid present=<bool> scheme=<…> field=<…>`: never the id itself. */
        fun logLine(): String = "spotify-mediaid present=${id != null} scheme=$scheme field=${field.label}"
    }

    fun pick(mediaId: String?, mediaUri: String?): Pick {
        filter(mediaId)?.let { return Pick(it, scheme(it), Field.MEDIA_ID) }
        filter(mediaUri)?.let { return Pick(it, scheme(it), Field.MEDIA_URI) }
        // Nothing usable. Say what was there, if anything, so "Spotify gives an id we can't use" is distinguishable from "none".
        return when {
            !mediaId.isNullOrBlank() -> Pick(null, scheme(mediaId), Field.MEDIA_ID)
            !mediaUri.isNullOrBlank() -> Pick(null, scheme(mediaUri), Field.MEDIA_URI)
            else -> Pick(null, "none", Field.NONE)
        }
    }
}

/** `notif.open` and its `notif.result` (PROTOCOL.md 13.2). */
object NotifOpen {
    fun result(key: String, ok: Boolean, error: String? = null, note: String? = null): Message = Message.of("notif.result") {
        put("key", key); put("ok", ok)
        if (error != null) put("error", error)
        if (note != null) put("note", note)
    }

    /** The package inside a `StatusBarNotification.key` (`user|pkg|id|tag|uid`), or null when it doesn't look like one. */
    fun packageOf(key: String): String? {
        val p = key.split('|')
        if (p.size < 3) return null
        return p[1].takeIf { it.isNotEmpty() && it.length <= 255 && it.all { c -> c.isLetterOrDigit() || c == '.' || c == '_' } }
    }
}

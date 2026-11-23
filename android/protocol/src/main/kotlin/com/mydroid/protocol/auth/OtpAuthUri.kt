package com.mydroid.protocol.auth

/** Parsing and building `otpauth://` URIs (the Google Authenticator "Key Uri Format"). */
object OtpAuthUri {
    fun isOtpAuth(raw: String) = raw.trimStart().startsWith("otpauth://", ignoreCase = true)

    /**
     * `otpauth://totp/Issuer:account?secret=BASE32&issuer=Issuer&algorithm=SHA1&digits=6&period=30` or `hotp` with `counter`.
     * The `issuer` parameter wins over a label prefix; with only a prefix, that is the issuer. Defaults: SHA1, 6 digits, 30 s.
     * Null when it isn't a usable otpauth URI (no or invalid secret, unknown type, odd digits or period).
     */
    fun parse(raw: String): AuthEntry? {
        val s = raw.trim()
        if (!isOtpAuth(s)) return null
        val rest = s.substring("otpauth://".length).substringBefore('#')
        val path = rest.substringBefore('?')
        val query = if (rest.contains('?')) rest.substringAfter('?') else ""
        val type = when (path.substringBefore('/').lowercase()) {
            "totp" -> OtpType.TOTP
            "hotp" -> OtpType.HOTP
            else -> return null
        }
        val label = Percent.decode(path.substringAfter('/', ""), plusAsSpace = false).trim()
        val params = HashMap<String, String>()
        for (pair in query.split('&')) {
            if (pair.isEmpty()) continue
            val k = Percent.decode(pair.substringBefore('='), true).lowercase()
            val v = Percent.decode(pair.substringAfter('=', ""), true)
            params.putIfAbsent(k, v)
        }
        val secret = Base32.normalize(params["secret"] ?: return null)
        if (!Base32.isValidSecret(secret)) return null

        var issuer = ""
        var account = label
        val colon = label.indexOf(':')
        if (colon >= 0) {
            issuer = label.substring(0, colon).trim()
            account = label.substring(colon + 1).trim()
        }
        params["issuer"]?.trim()?.takeIf { it.isNotEmpty() }?.let { issuer = it }

        val algorithm = if (params.containsKey("algorithm")) OtpAlgorithm.parse(params["algorithm"]) ?: return null else OtpAlgorithm.SHA1
        val digits = params["digits"]?.let { it.trim().toIntOrNull() ?: return null } ?: 6
        if (digits !in 6..8) return null
        val period = params["period"]?.let { it.trim().toIntOrNull() ?: return null } ?: 30
        if (period !in 1..86_400) return null
        val counter = params["counter"]?.trim()?.toLongOrNull() ?: 0L
        if (counter < 0) return null
        return AuthEntry(
            issuer = issuer, account = account, secret = secret, algorithm = algorithm, digits = digits, period = period, type = type, counter = counter,
            domains = IssuerDomains.forIssuer(issuer),
        )
    }

    fun build(e: AuthEntry): String {
        val label = if (e.issuer.isNotBlank()) "${Percent.encode(e.issuer)}:${Percent.encode(e.account)}" else Percent.encode(e.account)
        val sb = StringBuilder("otpauth://${e.type.name.lowercase()}/$label?secret=${e.secret}")
        if (e.issuer.isNotBlank()) sb.append("&issuer=").append(Percent.encode(e.issuer))
        sb.append("&algorithm=").append(e.algorithm.label).append("&digits=").append(e.digits)
        if (e.type == OtpType.TOTP) sb.append("&period=").append(e.period) else sb.append("&counter=").append(e.counter)
        return sb.toString()
    }
}

internal object Percent {
    fun decode(s: String, plusAsSpace: Boolean): String {
        if (s.indexOf('%') < 0 && !(plusAsSpace && s.indexOf('+') >= 0)) return s
        val sb = StringBuilder(s.length)
        val pending = java.io.ByteArrayOutputStream()
        fun flush() { if (pending.size() > 0) { sb.append(String(pending.toByteArray(), Charsets.UTF_8)); pending.reset() } }
        var i = 0
        while (i < s.length) {
            val c = s[i]
            if (c == '%' && i + 2 < s.length && hex(s[i + 1]) >= 0 && hex(s[i + 2]) >= 0) {
                pending.write(hex(s[i + 1]) * 16 + hex(s[i + 2])); i += 3
            } else {
                flush()
                sb.append(if (c == '+' && plusAsSpace) ' ' else c); i++
            }
        }
        flush()
        return sb.toString()
    }

    private fun hex(c: Char) = when (c) { in '0'..'9' -> c - '0'; in 'a'..'f' -> c - 'a' + 10; in 'A'..'F' -> c - 'A' + 10; else -> -1 }

    fun encode(s: String): String {
        val sb = StringBuilder()
        for (b in s.toByteArray(Charsets.UTF_8)) {
            val c = b.toInt() and 0xFF
            if ((c in 'A'.code..'Z'.code) || (c in 'a'.code..'z'.code) || (c in '0'.code..'9'.code) || c == '-'.code || c == '_'.code || c == '.'.code || c == '~'.code) sb.append(c.toChar())
            else sb.append('%').append("0123456789ABCDEF"[c shr 4]).append("0123456789ABCDEF"[c and 15])
        }
        return sb.toString()
    }
}

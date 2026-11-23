package com.mydroid.protocol.auth

/** RFC 4648 base32 (the alphabet authenticator secrets use). Decoding is forgiving: case, spaces, dashes and padding are ignored. */
object Base32 {
    private const val ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

    fun encode(data: ByteArray, padding: Boolean = false): String {
        val sb = StringBuilder((data.size * 8 + 4) / 5 + 8)
        var buffer = 0
        var bits = 0
        for (b in data) {
            buffer = (buffer shl 8) or (b.toInt() and 0xFF)
            bits += 8
            while (bits >= 5) {
                sb.append(ALPHABET[(buffer shr (bits - 5)) and 31])
                bits -= 5
            }
            buffer = buffer and ((1 shl bits) - 1)
        }
        if (bits > 0) sb.append(ALPHABET[(buffer shl (5 - bits)) and 31])
        if (padding) while (sb.length % 8 != 0) sb.append('=')
        return sb.toString()
    }

    /** Null when [text] has a character outside the alphabet or decodes to nothing. */
    fun decode(text: String): ByteArray? {
        val out = java.io.ByteArrayOutputStream(text.length * 5 / 8 + 1)
        var buffer = 0
        var bits = 0
        var seen = 0
        for (ch in text) {
            if (ch == '=' || ch == ' ' || ch == '-' || ch == '\t' || ch == '\n' || ch == '\r') continue
            val c = ch.uppercaseChar()
            val v = when (c) {
                in 'A'..'Z' -> c - 'A'
                in '2'..'7' -> c - '2' + 26
                else -> return null
            }
            seen++
            buffer = (buffer shl 5) or v
            bits += 5
            if (bits >= 8) {
                out.write((buffer shr (bits - 8)) and 0xFF)
                bits -= 8
                buffer = buffer and ((1 shl bits) - 1)
            }
        }
        if (seen == 0) return null
        return out.toByteArray().takeIf { it.isNotEmpty() }
    }

    /** True when [text] is a usable secret: valid base32 that decodes to at least 10 bytes (80 bits, RFC 4226's floor is 128 but real services use 80). */
    fun isValidSecret(text: String): Boolean = (decode(text)?.size ?: 0) >= 10

    /** Canonical form: upper case, no spaces or padding. */
    fun normalize(text: String): String = text.filter { it != ' ' && it != '-' && it != '=' && !it.isWhitespace() }.uppercase()
}

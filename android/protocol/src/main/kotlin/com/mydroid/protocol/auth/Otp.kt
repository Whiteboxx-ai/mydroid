package com.mydroid.protocol.auth

import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

enum class OtpAlgorithm(val jca: String, val label: String) {
    SHA1("HmacSHA1", "SHA1"), SHA256("HmacSHA256", "SHA256"), SHA512("HmacSHA512", "SHA512");

    companion object {
        fun parse(s: String?): OtpAlgorithm? = when (s?.trim()?.uppercase()?.replace("-", "")) {
            "SHA1", "SHA" -> SHA1
            "SHA256" -> SHA256
            "SHA512" -> SHA512
            else -> null
        }
    }
}

enum class OtpType { TOTP, HOTP }

/** HOTP (RFC 4226) and TOTP (RFC 6238). */
object Otp {
    private val POW10 = longArrayOf(1, 10, 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000, 1_000_000_000)

    /** RFC 4226 section 5.3: HMAC, dynamic truncation, [digits] decimal digits (1..9), zero padded. */
    fun hotp(secret: ByteArray, counter: Long, digits: Int = 6, algorithm: OtpAlgorithm = OtpAlgorithm.SHA1): String {
        require(digits in 1..9) { "digits must be 1..9" }
        require(secret.isNotEmpty()) { "empty secret" }
        val mac = Mac.getInstance(algorithm.jca)
        mac.init(SecretKeySpec(secret, algorithm.jca))
        val msg = ByteArray(8)
        var c = counter
        for (i in 7 downTo 0) { msg[i] = (c and 0xFF).toByte(); c = c ushr 8 }
        val h = mac.doFinal(msg)
        val off = h[h.size - 1].toInt() and 0x0F
        val bin = ((h[off].toInt() and 0x7F) shl 24) or ((h[off + 1].toInt() and 0xFF) shl 16) or
            ((h[off + 2].toInt() and 0xFF) shl 8) or (h[off + 3].toInt() and 0xFF)
        return (bin.toLong() % POW10[digits]).toString().padStart(digits, '0')
    }

    /** The time step for [unixSeconds] (T0 = 0). */
    fun step(unixSeconds: Long, period: Int = 30): Long = Math.floorDiv(unixSeconds, period.toLong())

    fun totp(secret: ByteArray, unixSeconds: Long, digits: Int = 6, period: Int = 30, algorithm: OtpAlgorithm = OtpAlgorithm.SHA1): String {
        require(period > 0) { "period must be positive" }
        return hotp(secret, step(unixSeconds, period), digits, algorithm)
    }

    /** Whole seconds left in the period that contains [unixSeconds] (1..period). */
    fun secondsRemaining(unixSeconds: Long, period: Int = 30): Int = period - Math.floorMod(unixSeconds, period.toLong()).toInt()

    /** The fraction of the period still left, for a countdown ring (millisecond precision). */
    fun fractionRemaining(unixMillis: Long, period: Int = 30): Float {
        val into = Math.floorMod(unixMillis, period * 1000L)
        return 1f - into.toFloat() / (period * 1000f)
    }
}

package com.mydroid.protocol

import java.security.MessageDigest
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** HKDF-SHA256 (RFC 5869) on top of javax.crypto.Mac. */
object Hkdf {
    private const val ALG = "HmacSHA256"
    private const val HASH_LEN = 32

    fun extract(salt: ByteArray, ikm: ByteArray): ByteArray {
        val mac = Mac.getInstance(ALG)
        // RFC 5869: an empty salt is treated as HashLen zero bytes.
        val key = if (salt.isEmpty()) ByteArray(HASH_LEN) else salt
        mac.init(SecretKeySpec(key, ALG))
        return mac.doFinal(ikm)
    }

    fun expand(prk: ByteArray, info: ByteArray, length: Int): ByteArray {
        require(length in 1..255 * HASH_LEN)
        val mac = Mac.getInstance(ALG)
        mac.init(SecretKeySpec(prk, ALG))
        val out = ByteArray(length)
        var t = ByteArray(0)
        var pos = 0
        var counter = 1
        while (pos < length) {
            mac.update(t)
            mac.update(info)
            mac.update(counter.toByte())
            t = mac.doFinal()
            val n = minOf(t.size, length - pos)
            System.arraycopy(t, 0, out, pos, n)
            pos += n
            counter++
        }
        return out
    }

    fun derive(ikm: ByteArray, salt: ByteArray, info: String, length: Int): ByteArray =
        expand(extract(salt, ikm), info.toByteArray(Charsets.UTF_8), length)
}

class SessionKeys(val c2s: ByteArray, val s2c: ByteArray, val confirmCode: String)

object Keys {
    fun ltkFromSecret(secret: ByteArray): ByteArray =
        Hkdf.derive(secret, ByteArray(0), "mydroid v1 ltk", 32)

    fun session(ltk: ByteArray, nonceC: ByteArray, nonceS: ByteArray): SessionKeys {
        val salt = nonceC + nonceS
        val k = Hkdf.derive(ltk, salt, "mydroid v1 session", 64)
        val confirm = Hkdf.derive(ltk, salt, "mydroid v1 confirm", 4)
        val n = ((confirm[0].toLong() and 0xff) shl 24) or ((confirm[1].toLong() and 0xff) shl 16) or
            ((confirm[2].toLong() and 0xff) shl 8) or (confirm[3].toLong() and 0xff)
        val code = (n % 1_000_000L).toString().padStart(6, '0')
        return SessionKeys(k.copyOfRange(0, 32), k.copyOfRange(32, 64), code)
    }

    /** "181734" -> "181 734" */
    fun displayCode(code: String): String = if (code.length == 6) code.substring(0, 3) + " " + code.substring(3) else code
}

/** AES-256-GCM frame sealing: body = nonce(12) || ciphertext || tag(16), no AAD. */
class FrameCipher(key: ByteArray) {
    private val keySpec = SecretKeySpec(key, "AES")

    fun nonceFor(counter: Long): ByteArray {
        val n = ByteArray(12)
        for (i in 0 until 8) n[11 - i] = (counter ushr (8 * i)).toByte()
        return n
    }

    fun seal(counter: Long, plaintext: ByteArray): ByteArray {
        val nonce = nonceFor(counter)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, keySpec, GCMParameterSpec(128, nonce))
        return nonce + c.doFinal(plaintext)
    }

    /** Throws ProtocolException on counter mismatch or auth failure. */
    fun open(expectedCounter: Long, body: ByteArray): ByteArray {
        if (body.size < 12 + 16) throw ProtocolException("frame too short")
        val expected = nonceFor(expectedCounter)
        if (!MessageDigest.isEqual(expected, body.copyOfRange(0, 12))) throw ProtocolException("counter mismatch")
        try {
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, keySpec, GCMParameterSpec(128, expected))
            return c.doFinal(body, 12, body.size - 12)
        } catch (e: java.security.GeneralSecurityException) {
            throw ProtocolException("decryption failed")
        }
    }
}

class ProtocolException(msg: String) : java.io.IOException(msg)

object Hex {
    fun encode(b: ByteArray): String = b.joinToString("") { "%02x".format(it) }
    fun decode(s: String): ByteArray = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
}

object B64 {
    fun std(b: ByteArray): String = Base64.getEncoder().encodeToString(b)
    fun decodeStd(s: String): ByteArray = Base64.getDecoder().decode(s)
    fun decodeUrl(s: String): ByteArray = Base64.getUrlDecoder().decode(s)
}

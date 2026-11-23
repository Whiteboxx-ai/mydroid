package com.mydroid.protocol.auth

import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.nio.ByteBuffer
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * The only way secrets ever leave the phone: a file sealed with the user's passphrase.
 *
 *     "MYDRAUTH" | version u8 (1) | header length u16 | header JSON | AES-256-GCM ciphertext+tag of the vault JSON
 *     header = {"kdf":"scrypt","n":32768,"r":8,"p":1,"salt":b64(16),"iv":b64(12)}
 *
 * The magic, version and header are the GCM associated data, so changing any of them fails the tag.
 */
object AuthBackup {
    private val MAGIC = "MYDRAUTH".toByteArray(Charsets.US_ASCII)
    const val VERSION = 1
    const val DEFAULT_N = 1 shl 15
    const val DEFAULT_R = 8
    const val DEFAULT_P = 1
    /** A backup asking for more than ~64 MiB of scrypt memory is refused rather than risking an out-of-memory crash. */
    private const val MAX_N_TIMES_R = 1 shl 19

    enum class Failure { NotABackup, UnsupportedVersion, WrongPassphrase, Corrupt }
    class BackupException(val failure: Failure) : Exception(failure.name)

    @Serializable
    private class Header(val kdf: String, val n: Int, val r: Int, val p: Int, val salt: String, val iv: String)

    @Serializable
    private class Vault(val v: Int = 1, val createdAt: Long = 0, val entries: List<AuthEntry>)

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val rng = SecureRandom()

    /** [n] is a parameter so tests can be fast; the app uses the defaults. */
    fun encrypt(entries: List<AuthEntry>, passphrase: CharArray, createdAt: Long, n: Int = DEFAULT_N, r: Int = DEFAULT_R, p: Int = DEFAULT_P): ByteArray {
        val salt = ByteArray(16).also(rng::nextBytes)
        val iv = ByteArray(12).also(rng::nextBytes)
        val h = Header("scrypt", n, r, p, Base64.getEncoder().encodeToString(salt), Base64.getEncoder().encodeToString(iv))
        val headerBytes = json.encodeToString(h).toByteArray(Charsets.UTF_8)
        val aad = aad(headerBytes)
        val plain = json.encodeToString(Vault(1, createdAt, entries)).toByteArray(Charsets.UTF_8)
        val key = derive(passphrase, salt, n, r, p)
        try {
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
            c.updateAAD(aad)
            val ct = c.doFinal(plain)
            return aad + ct
        } finally { key.fill(0); plain.fill(0) }
    }

    /** Throws [BackupException]. A wrong passphrase and a tampered file are indistinguishable by design; both read as [Failure.WrongPassphrase]. */
    fun decrypt(file: ByteArray, passphrase: CharArray): List<AuthEntry> {
        if (file.size < MAGIC.size + 3 || !file.copyOfRange(0, MAGIC.size).contentEquals(MAGIC)) throw BackupException(Failure.NotABackup)
        val bb = ByteBuffer.wrap(file, MAGIC.size, file.size - MAGIC.size)
        val version = bb.get().toInt() and 0xFF
        if (version != VERSION) throw BackupException(Failure.UnsupportedVersion)
        val hl = bb.short.toInt() and 0xFFFF
        if (hl > bb.remaining()) throw BackupException(Failure.Corrupt)
        val headerBytes = ByteArray(hl).also { bb.get(it) }
        val header = try { json.decodeFromString<Header>(String(headerBytes, Charsets.UTF_8)) } catch (e: Exception) { throw BackupException(Failure.Corrupt) }
        if (header.kdf != "scrypt" || header.n < 2 || header.n and (header.n - 1) != 0 || header.r < 1 || header.p < 1 ||
            header.n.toLong() * header.r > MAX_N_TIMES_R || header.p > 16) throw BackupException(Failure.Corrupt)
        val salt = try { Base64.getDecoder().decode(header.salt) } catch (e: Exception) { throw BackupException(Failure.Corrupt) }
        val iv = try { Base64.getDecoder().decode(header.iv) } catch (e: Exception) { throw BackupException(Failure.Corrupt) }
        if (iv.size != 12) throw BackupException(Failure.Corrupt)
        val ct = ByteArray(bb.remaining()).also { bb.get(it) }
        val key = derive(passphrase, salt, header.n, header.r, header.p)
        val plain = try {
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
            c.updateAAD(aad(headerBytes))
            c.doFinal(ct)
        } catch (e: Exception) {
            throw BackupException(Failure.WrongPassphrase)
        } finally { key.fill(0) }
        try {
            val v = json.decodeFromString<Vault>(String(plain, Charsets.UTF_8))
            return v.entries.filter { Base32.isValidSecret(it.secret) }
        } catch (e: Exception) {
            throw BackupException(Failure.Corrupt)
        } finally { plain.fill(0) }
    }

    private fun aad(headerBytes: ByteArray): ByteArray =
        ByteBuffer.allocate(MAGIC.size + 1 + 2 + headerBytes.size).put(MAGIC).put(VERSION.toByte()).putShort(headerBytes.size.toShort()).put(headerBytes).array()

    private fun derive(passphrase: CharArray, salt: ByteArray, n: Int, r: Int, p: Int): ByteArray {
        val pw = String(passphrase).toByteArray(Charsets.UTF_8)
        try { return Scrypt.derive(pw, salt, n, r, p, 32) } finally { pw.fill(0) }
    }
}

/** A rough strength read for the backup passphrase screen. Not a guarantee, just a nudge. */
object PassphraseStrength {
    enum class Level(val label: String) { Weak("Weak"), Fair("Fair"), Good("Good"), Strong("Strong") }

    private val common = setOf("password", "passw0rd", "12345678", "123456789", "qwertyuiop", "iloveyou", "letmein123", "welcome123", "admin1234", "11111111")

    fun level(p: String): Level {
        if (p.length < 8) return Level.Weak
        val lower = p.lowercase()
        if (lower in common || common.any { lower.startsWith(it) && p.length <= it.length + 2 }) return Level.Weak
        val classes = listOf(p.any { it.isLowerCase() }, p.any { it.isUpperCase() }, p.any { it.isDigit() }, p.any { !it.isLetterOrDigit() }).count { it }
        val distinct = p.toSet().size
        if (distinct <= 3) return Level.Weak
        val words = p.trim().split(Regex("\\s+")).size
        // A passphrase of 4+ words is strong even in plain lower case; otherwise length and variety decide.
        val score = (p.length / 4) + classes * 2 + (if (words >= 4) 6 else 0) + (if (distinct < p.length / 2) -3 else 0)
        return when {
            p.length >= 8 && score < 8 -> Level.Weak
            score < 10 -> Level.Fair
            score < 12 -> Level.Good
            else -> Level.Strong
        }
    }

    /** Minimum the app accepts: 8 characters and not Weak. */
    fun acceptable(p: String) = level(p) != Level.Weak
}

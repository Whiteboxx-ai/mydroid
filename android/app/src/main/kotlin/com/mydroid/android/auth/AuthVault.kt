package com.mydroid.android.auth

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import com.mydroid.protocol.auth.AuthEntry
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Seals and opens the vault bytes. The app uses the Keystore; JVM tests use a plain AES key. */
interface SecretBox {
    fun seal(plain: ByteArray): ByteArray
    /** Null when the bytes can't be opened (tampered, or the key is gone). */
    fun open(sealed: ByteArray): ByteArray?
    fun destroyKey() {}
}

/**
 * AES-256-GCM with a non-exportable Android Keystore key. StrongBox (a separate secure chip) is used when the phone has one,
 * else the TEE. The key needs no user authentication: the Mac must be able to get an approved code while the phone is locked in a
 * pocket (the approval itself requires an unlock on Android 12+). The biometric gate is a screen lock for the list, not the key.
 */
object KeystoreVaultBox : SecretBox {
    private const val ALIAS = "mydroid_auth_vault"
    private const val PROVIDER = "AndroidKeyStore"

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance(PROVIDER).apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        fun spec(strongBox: Boolean) = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .apply { if (strongBox && Build.VERSION.SDK_INT >= 28) setIsStrongBoxBacked(true) }
            .build()
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER)
        if (Build.VERSION.SDK_INT >= 28) {
            try { gen.init(spec(true)); return gen.generateKey() } catch (e: StrongBoxUnavailableException) { /* no secure chip: fall through to the TEE */ } catch (e: Exception) { /* some ROMs throw something else */ }
        }
        gen.init(spec(false))
        return gen.generateKey()
    }

    override fun seal(plain: ByteArray): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key())
        return c.iv + c.doFinal(plain)
    }

    override fun open(sealed: ByteArray): ByteArray? = try {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, sealed, 0, 12))
        c.doFinal(sealed, 12, sealed.size - 12)
    } catch (e: Exception) { null }

    override fun destroyKey() { runCatching { KeyStore.getInstance(PROVIDER).apply { load(null) }.deleteEntry(ALIAS) } }
}

/**
 * The accounts, encrypted at rest in one file. Everything is held in memory once read; the file is rewritten atomically on each change.
 * Nothing here logs: not secrets, not codes, not issuers or accounts.
 */
class AuthVault(private val file: File, private val box: SecretBox) {
    enum class Health { Ok, Unreadable }

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val ser = ListSerializer(AuthEntry.serializer())
    private val _entries = MutableStateFlow<List<AuthEntry>>(emptyList())
    val entries: StateFlow<List<AuthEntry>> get() = _entries
    @Volatile var health: Health = Health.Ok; private set
    private var loaded = false

    @Synchronized
    private fun load() {
        if (loaded) return
        loaded = true
        if (!file.exists()) return
        val plain = try { file.readBytes().let(box::open) } catch (e: Exception) { null }
        if (plain == null) { health = Health.Unreadable; return }
        try {
            _entries.value = json.decodeFromString(ser, String(plain, Charsets.UTF_8))
        } catch (e: Exception) { health = Health.Unreadable } finally { plain.fill(0) }
        migrateDomains()
    }

    /**
     * Early builds gave AWS entries plain "amazon.com", so AWS codes could be offered on Amazon shopping and vice versa.
     * Drop it from entries whose issuer is AWS (identified by the built-in map pointing at aws.amazon.com).
     */
    private fun migrateDomains() {
        val fixed = _entries.value.map { e ->
            val aws = com.mydroid.protocol.auth.IssuerDomains.forIssuer(e.issuer).contains("aws.amazon.com")
            if (aws && e.domains.any { it.equals("amazon.com", ignoreCase = true) })
                e.copy(domains = e.domains.filterNot { it.equals("amazon.com", ignoreCase = true) }.ifEmpty { listOf("aws.amazon.com") })
            else e
        }
        if (fixed != _entries.value) commit(fixed)
    }

    fun all(): List<AuthEntry> { load(); return _entries.value }
    val count: Int get() = all().size
    fun get(id: String): AuthEntry? = all().firstOrNull { it.id == id }

    @Synchronized
    private fun commit(next: List<AuthEntry>) {
        load()
        if (health == Health.Unreadable && file.exists()) {
            // Keep the unreadable file for a restore attempt; start a fresh vault beside it.
            runCatching { file.renameTo(File(file.parentFile, file.name + ".unreadable")) }
            health = Health.Ok
        }
        val plain = json.encodeToString(ser, next).toByteArray(Charsets.UTF_8)
        try {
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeBytes(box.seal(plain))
            if (!tmp.renameTo(file)) { file.delete(); tmp.renameTo(file) }
        } finally { plain.fill(0) }
        _entries.value = next
    }

    @Synchronized fun add(items: List<AuthEntry>): Int {
        load()
        val fresh = com.mydroid.protocol.auth.AuthEntries.newOnly(_entries.value, items)
        if (fresh.isNotEmpty()) commit(_entries.value + fresh)
        return fresh.size
    }

    @Synchronized fun update(e: AuthEntry) { load(); commit(_entries.value.map { if (it.id == e.id) e else it }) }

    @Synchronized fun delete(id: String) { load(); commit(_entries.value.filter { it.id != id }) }

    @Synchronized fun setDomains(id: String, domains: List<String>) {
        load(); get(id)?.let { commit(_entries.value.map { x -> if (x.id == id) x.copy(domains = domains) else x }) }
    }

    /** HOTP: the counter moves on after a code has been shown or sent. */
    @Synchronized fun advanceCounter(id: String) {
        load(); get(id)?.takeIf { it.type == com.mydroid.protocol.auth.OtpType.HOTP }?.let { e -> commit(_entries.value.map { x -> if (x.id == id) e.copy(counter = e.counter + 1) else x }) }
    }

    @Synchronized fun deleteAll() {
        loaded = true; health = Health.Ok
        file.delete(); File(file.parentFile, file.name + ".unreadable").delete(); File(file.parentFile, file.name + ".tmp").delete()
        box.destroyKey()
        _entries.value = emptyList()
    }
}

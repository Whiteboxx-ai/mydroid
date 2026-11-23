package com.mydroid.protocol.auth

import kotlinx.serialization.Serializable
import java.util.UUID

/** One account in the phone's vault (PROTOCOL.md 14.1). [secret] is base32 and never leaves the phone except inside an encrypted backup. */
@Serializable
data class AuthEntry(
    val id: String = UUID.randomUUID().toString(),
    val issuer: String = "",
    val account: String = "",
    val secret: String,
    val algorithm: OtpAlgorithm = OtpAlgorithm.SHA1,
    val digits: Int = 6,
    val period: Int = 30,
    val type: OtpType = OtpType.TOTP,
    val counter: Long = 0,
    val domains: List<String> = emptyList(),
) {
    val secretBytes: ByteArray? get() = Base32.decode(secret)

    /** Name for lists and prompts: "Salesforce", or the account when there is no issuer. */
    val title: String get() = issuer.ifBlank { account.ifBlank { "Account" } }

    /** The code for [unixSeconds] (TOTP) or the current counter (HOTP). Null when the secret is unusable. */
    fun code(unixSeconds: Long): String? {
        val key = secretBytes ?: return null
        return when (type) {
            OtpType.TOTP -> Otp.totp(key, unixSeconds, digits, period, algorithm)
            OtpType.HOTP -> Otp.hotp(key, counter, digits, algorithm)
        }
    }

    /** Same account, whatever else changed: used to skip duplicates on import. */
    fun sameSecretAs(o: AuthEntry) = Base32.normalize(secret) == Base32.normalize(o.secret)

    /** Never prints the secret. */
    override fun toString() = "AuthEntry(id=$id)"
}

object AuthEntries {
    /** Drops entries of [incoming] whose secret is already in [existing] (or earlier in [incoming]). */
    fun newOnly(existing: List<AuthEntry>, incoming: List<AuthEntry>): List<AuthEntry> {
        val seen = existing.mapTo(HashSet()) { Base32.normalize(it.secret) }
        return incoming.filter { seen.add(Base32.normalize(it.secret)) }
    }
}

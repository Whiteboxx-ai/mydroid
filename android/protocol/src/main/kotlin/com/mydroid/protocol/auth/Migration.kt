package com.mydroid.protocol.auth

import java.util.Base64

/**
 * Google Authenticator "Transfer accounts" export: `otpauth-migration://offline?data=<base64 protobuf MigrationPayload>`.
 * The schema is tiny, so the protobuf wire format is read by hand:
 *
 *     message OtpParameters { bytes secret=1; string name=2; string issuer=3; Algorithm algorithm=4; DigitCount digits=5; OtpType type=6; int64 counter=7; }
 *     message MigrationPayload { repeated OtpParameters otp_parameters=1; int32 version=2; int32 batch_size=3; int32 batch_index=4; int32 batch_id=5; }
 */
object Migration {
    class Payload(val entries: List<AuthEntry>, val skipped: Int, val version: Int, val batchSize: Int, val batchIndex: Int, val batchId: Int)

    fun isMigration(raw: String) = raw.trimStart().startsWith("otpauth-migration://", ignoreCase = true)

    /** Null when [raw] is not a well-formed migration URI. */
    fun parse(raw: String): Payload? {
        val s = raw.trim()
        if (!isMigration(s)) return null
        val query = s.substringAfter('?', "").substringBefore('#')
        var data: String? = null
        for (pair in query.split('&')) {
            if (Percent.decode(pair.substringBefore('='), true).equals("data", ignoreCase = true)) { data = pair.substringAfter('=', ""); break }
        }
        // '+' is a real base64 character here: only %XX is decoded, and a '+' turned into a space by a lenient URL layer is put back.
        val b64 = Percent.decode(data ?: return null, plusAsSpace = false).replace(' ', '+').filter { !it.isWhitespace() }
        val bytes = decodeBase64(b64) ?: return null
        return decode(bytes)
    }

    private fun decodeBase64(s: String): ByteArray? = try {
        val unpadded = s.trimEnd('=')
        val padded = unpadded + "=".repeat((4 - unpadded.length % 4) % 4)
        val out = if (s.contains('-') || s.contains('_')) Base64.getUrlDecoder().decode(padded) else Base64.getDecoder().decode(padded)
        out.takeIf { it.isNotEmpty() }
    } catch (e: IllegalArgumentException) { null }

    fun decode(bytes: ByteArray): Payload? = try {
        val r = Reader(bytes)
        val entries = ArrayList<AuthEntry>()
        var skipped = 0
        var version = 0; var size = 0; var index = 0; var id = 0
        while (!r.done) {
            val tag = r.varint()
            val field = (tag ushr 3).toInt()
            when {
                field == 1 && (tag and 7L) == 2L -> {
                    val e = otpParameters(r.bytes())
                    if (e == null) skipped++ else entries += e
                }
                field == 2 && (tag and 7L) == 0L -> version = r.varint().toInt()
                field == 3 && (tag and 7L) == 0L -> size = r.varint().toInt()
                field == 4 && (tag and 7L) == 0L -> index = r.varint().toInt()
                field == 5 && (tag and 7L) == 0L -> id = r.varint().toInt()
                else -> r.skip((tag and 7L).toInt())
            }
        }
        Payload(entries, skipped, version, size, index, id)
    } catch (e: Malformed) { null }

    private fun otpParameters(bytes: ByteArray): AuthEntry? {
        val r = Reader(bytes)
        var secret = ByteArray(0); var name = ""; var issuer = ""
        var alg = 0; var dig = 0; var type = 0; var counter = 0L
        while (!r.done) {
            val tag = r.varint()
            val wire = (tag and 7L).toInt()
            when ((tag ushr 3).toInt()) {
                1 -> if (wire == 2) secret = r.bytes() else r.skip(wire)
                2 -> if (wire == 2) name = String(r.bytes(), Charsets.UTF_8) else r.skip(wire)
                3 -> if (wire == 2) issuer = String(r.bytes(), Charsets.UTF_8) else r.skip(wire)
                4 -> if (wire == 0) alg = r.varint().toInt() else r.skip(wire)
                5 -> if (wire == 0) dig = r.varint().toInt() else r.skip(wire)
                6 -> if (wire == 0) type = r.varint().toInt() else r.skip(wire)
                7 -> if (wire == 0) counter = r.varint() else r.skip(wire)
                else -> r.skip(wire)
            }
        }
        if (secret.isEmpty()) return null
        val algorithm = when (alg) { 0, 1 -> OtpAlgorithm.SHA1; 2 -> OtpAlgorithm.SHA256; 3 -> OtpAlgorithm.SHA512; else -> return null } // 4 = MD5: unsupported
        val digits = when (dig) { 0, 1 -> 6; 2 -> 8; else -> return null }
        val otpType = when (type) { 0, 2 -> OtpType.TOTP; 1 -> OtpType.HOTP; else -> return null }
        // Google writes "Issuer:account" in the name when it also has an issuer; show the account alone then.
        var account = name.trim()
        if (issuer.isNotBlank() && account.startsWith("$issuer:", ignoreCase = true)) account = account.substring(issuer.length + 1).trim()
        else if (issuer.isBlank() && account.contains(':')) { issuer = account.substringBefore(':').trim(); account = account.substringAfter(':').trim() }
        return AuthEntry(
            issuer = issuer.trim(), account = account, secret = Base32.encode(secret), algorithm = algorithm, digits = digits,
            type = otpType, counter = counter, domains = IssuerDomains.forIssuer(issuer),
        )
    }

    private class Malformed : Exception()

    private class Reader(bytes: ByteArray) {
        private val b = bytes
        private var p = 0
        val done get() = p >= b.size

        fun varint(): Long {
            var result = 0L
            var shift = 0
            while (true) {
                if (p >= b.size || shift > 63) throw Malformed()
                val x = b[p++].toInt()
                result = result or ((x and 0x7F).toLong() shl shift)
                if (x and 0x80 == 0) return result
                shift += 7
            }
        }

        fun bytes(): ByteArray {
            val n = varint()
            if (n < 0 || n > b.size - p) throw Malformed()
            return b.copyOfRange(p, p + n.toInt()).also { p += n.toInt() }
        }

        fun skip(wire: Int) {
            when (wire) {
                0 -> varint()
                1 -> advance(8)
                2 -> bytes()
                5 -> advance(4)
                else -> throw Malformed()
            }
        }

        private fun advance(n: Int) { if (p + n > b.size) throw Malformed(); p += n }
    }
}

/** Collects the parts of a multi-QR Google export ("2 of 3 scanned"). A different `batch_id` starts over. */
class MigrationBatch {
    private val parts = java.util.TreeMap<Int, Migration.Payload>()
    var batchId: Int? = null; private set
    var size = 1; private set
    private var skippedTotal = 0

    enum class Result { Added, Duplicate, NewBatch, Invalid }

    fun add(p: Migration.Payload): Result {
        val sz = maxOf(p.batchSize, 1)
        var res = Result.Added
        if (batchId != null && (batchId != p.batchId || size != sz)) { parts.clear(); skippedTotal = 0; res = Result.NewBatch }
        batchId = p.batchId; size = sz
        if (p.batchIndex !in 0 until sz) return Result.Invalid
        if (parts.containsKey(p.batchIndex)) return Result.Duplicate
        parts[p.batchIndex] = p
        skippedTotal += p.skipped
        return res
    }

    val scanned get() = parts.size
    val isComplete get() = batchId != null && parts.size == size
    /** Part numbers (1-based) still to scan. */
    val missing: List<Int> get() = (0 until size).filter { it !in parts }.map { it + 1 }
    val skipped get() = skippedTotal
    val entries: List<AuthEntry> get() = parts.values.flatMap { it.entries }
    fun reset() { parts.clear(); batchId = null; size = 1; skippedTotal = 0 }
}

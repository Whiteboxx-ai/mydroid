package com.mydroid.protocol.auth

import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** scrypt (RFC 7914) with no dependencies: PBKDF2-HMAC-SHA256 around ROMix over Salsa20/8. Checked against the RFC's vectors. */
object Scrypt {
    fun derive(password: ByteArray, salt: ByteArray, n: Int, r: Int, p: Int, dkLen: Int): ByteArray {
        require(n >= 2 && n and (n - 1) == 0) { "N must be a power of two" }
        require(r >= 1 && p >= 1 && dkLen >= 1)
        val blockBytes = 128 * r
        val b = pbkdf2(password, salt, 1, p * blockBytes)
        val words = 32 * r
        val v = IntArray(words * n)
        val x = IntArray(words); val y = IntArray(words); val t = IntArray(16)
        for (i in 0 until p) {
            val off = i * blockBytes
            for (k in 0 until words) x[k] = le32(b, off + 4 * k)
            roMix(x, y, v, n, r, t)
            for (k in 0 until words) put32(b, off + 4 * k, x[k])
        }
        v.fill(0)
        return pbkdf2(password, b, 1, dkLen)
    }

    fun pbkdf2(password: ByteArray, salt: ByteArray, iterations: Int, dkLen: Int): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        // SecretKeySpec refuses a zero-length key; HMAC pads a short key with zeros, so one zero byte is the same key.
        mac.init(SecretKeySpec(if (password.isEmpty()) ByteArray(1) else password, "HmacSHA256"))
        val out = ByteArray(dkLen)
        var block = 1
        var pos = 0
        while (pos < dkLen) {
            mac.update(salt)
            mac.update(byteArrayOf((block ushr 24).toByte(), (block ushr 16).toByte(), (block ushr 8).toByte(), block.toByte()))
            var u = mac.doFinal()
            val t = u.copyOf()
            for (i in 1 until iterations) {
                u = mac.doFinal(u)
                for (k in t.indices) t[k] = (t[k].toInt() xor u[k].toInt()).toByte()
            }
            val n = minOf(t.size, dkLen - pos)
            System.arraycopy(t, 0, out, pos, n)
            pos += n; block++
        }
        return out
    }

    private fun roMix(x: IntArray, y: IntArray, v: IntArray, n: Int, r: Int, t: IntArray) {
        val words = 32 * r
        for (i in 0 until n) {
            System.arraycopy(x, 0, v, i * words, words)
            blockMix(x, y, r, t)
            System.arraycopy(y, 0, x, 0, words)
        }
        for (i in 0 until n) {
            val j = x[(2 * r - 1) * 16] and (n - 1)
            val base = j * words
            for (k in 0 until words) x[k] = x[k] xor v[base + k]
            blockMix(x, y, r, t)
            System.arraycopy(y, 0, x, 0, words)
        }
    }

    private fun blockMix(b: IntArray, y: IntArray, r: Int, x: IntArray) {
        System.arraycopy(b, (2 * r - 1) * 16, x, 0, 16)
        for (i in 0 until 2 * r) {
            for (k in 0 until 16) x[k] = x[k] xor b[i * 16 + k]
            salsa8(x)
            val dst = if (i % 2 == 0) (i / 2) * 16 else (r + i / 2) * 16
            System.arraycopy(x, 0, y, dst, 16)
        }
    }

    private fun rotl(a: Int, b: Int) = (a shl b) or (a ushr (32 - b))

    private fun salsa8(b: IntArray) {
        val x = b.copyOf()
        repeat(4) {
            x[4] = x[4] xor rotl(x[0] + x[12], 7); x[8] = x[8] xor rotl(x[4] + x[0], 9)
            x[12] = x[12] xor rotl(x[8] + x[4], 13); x[0] = x[0] xor rotl(x[12] + x[8], 18)
            x[9] = x[9] xor rotl(x[5] + x[1], 7); x[13] = x[13] xor rotl(x[9] + x[5], 9)
            x[1] = x[1] xor rotl(x[13] + x[9], 13); x[5] = x[5] xor rotl(x[1] + x[13], 18)
            x[14] = x[14] xor rotl(x[10] + x[6], 7); x[2] = x[2] xor rotl(x[14] + x[10], 9)
            x[6] = x[6] xor rotl(x[2] + x[14], 13); x[10] = x[10] xor rotl(x[6] + x[2], 18)
            x[3] = x[3] xor rotl(x[15] + x[11], 7); x[7] = x[7] xor rotl(x[3] + x[15], 9)
            x[11] = x[11] xor rotl(x[7] + x[3], 13); x[15] = x[15] xor rotl(x[11] + x[7], 18)
            x[1] = x[1] xor rotl(x[0] + x[3], 7); x[2] = x[2] xor rotl(x[1] + x[0], 9)
            x[3] = x[3] xor rotl(x[2] + x[1], 13); x[0] = x[0] xor rotl(x[3] + x[2], 18)
            x[6] = x[6] xor rotl(x[5] + x[4], 7); x[7] = x[7] xor rotl(x[6] + x[5], 9)
            x[4] = x[4] xor rotl(x[7] + x[6], 13); x[5] = x[5] xor rotl(x[4] + x[7], 18)
            x[11] = x[11] xor rotl(x[10] + x[9], 7); x[8] = x[8] xor rotl(x[11] + x[10], 9)
            x[9] = x[9] xor rotl(x[8] + x[11], 13); x[10] = x[10] xor rotl(x[9] + x[8], 18)
            x[12] = x[12] xor rotl(x[15] + x[14], 7); x[13] = x[13] xor rotl(x[12] + x[15], 9)
            x[14] = x[14] xor rotl(x[13] + x[12], 13); x[15] = x[15] xor rotl(x[14] + x[13], 18)
        }
        for (i in 0 until 16) b[i] += x[i]
    }

    private fun le32(b: ByteArray, o: Int) =
        (b[o].toInt() and 0xFF) or ((b[o + 1].toInt() and 0xFF) shl 8) or ((b[o + 2].toInt() and 0xFF) shl 16) or ((b[o + 3].toInt() and 0xFF) shl 24)

    private fun put32(b: ByteArray, o: Int, v: Int) {
        b[o] = v.toByte(); b[o + 1] = (v ushr 8).toByte(); b[o + 2] = (v ushr 16).toByte(); b[o + 3] = (v ushr 24).toByte()
    }
}

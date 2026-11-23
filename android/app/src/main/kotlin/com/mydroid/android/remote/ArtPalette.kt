package com.mydroid.android.remote

import kotlin.math.max
import kotlin.math.min

/**
 * Picks the colours that wash behind the Playing screen from a small copy of the cover (ARGB pixels). Plain Kotlin on ints,
 * so it is tested without a device. The result is always dark enough to carry white text.
 */
object ArtPalette {
    private const val BUCKETS = 12

    /** Up to three ARGB colours, most prominent first; a neutral dark grey when the cover has no colour to speak of. */
    fun wash(pixels: IntArray): List<Int> {
        val weight = DoubleArray(BUCKETS)
        val sumR = DoubleArray(BUCKETS); val sumG = DoubleArray(BUCKETS); val sumB = DoubleArray(BUCKETS); val n = DoubleArray(BUCKETS)
        for (p in pixels) {
            if ((p ushr 24) < 128) continue
            val r = (p shr 16 and 0xFF) / 255.0; val g = (p shr 8 and 0xFF) / 255.0; val b = (p and 0xFF) / 255.0
            val mx = max(r, max(g, b)); val mn = min(r, min(g, b)); val d = mx - mn
            val s = if (mx == 0.0) 0.0 else d / mx
            if (mx < 0.15 || s < 0.18) continue           // near-black and grey say nothing about the cover
            val h = when {
                d == 0.0 -> 0.0
                mx == r -> ((g - b) / d + 6) % 6
                mx == g -> (b - r) / d + 2
                else -> (r - g) / d + 4
            } / 6.0
            val k = (h * BUCKETS).toInt().coerceIn(0, BUCKETS - 1)
            weight[k] += s * mx; sumR[k] += r; sumG[k] += g; sumB[k] += b; n[k] += 1.0
        }
        val order = (0 until BUCKETS).filter { n[it] > 0 }.sortedByDescending { weight[it] }
        if (order.isEmpty()) return listOf(NEUTRAL)
        val picked = ArrayList<Int>()
        val used = ArrayList<Int>()
        for (k in order) {
            // A second and third colour must be a different hue, not the same one again.
            if (used.any { circular(it, k) < 2 }) continue
            used += k; picked += darken(sumR[k] / n[k], sumG[k] / n[k], sumB[k] / n[k])
            if (picked.size == 3) break
        }
        return picked
    }

    private fun circular(a: Int, b: Int): Int { val d = kotlin.math.abs(a - b); return min(d, BUCKETS - d) }

    /** Keeps the hue, lifts a washed-out colour a little and pulls a bright one down to about 55% brightness. */
    private fun darken(r: Double, g: Double, b: Double): Int {
        val mx = max(r, max(g, b)); val mn = min(r, min(g, b))
        val target = mx.coerceIn(0.32, 0.55)
        val k = if (mx == 0.0) 0.0 else target / mx
        fun c(v: Double) = ((v * k).coerceIn(0.0, 1.0) * 255).toInt()
        return (0xFF shl 24) or (c(r) shl 16) or (c(g) shl 8) or c(b)
    }

    const val NEUTRAL: Int = 0xFF2B2F2E.toInt()
}

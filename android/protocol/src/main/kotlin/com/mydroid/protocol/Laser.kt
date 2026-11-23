package com.mydroid.protocol

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.asin
import kotlin.math.atan2
import kotlin.math.hypot

/**
 * Phone orientation to a point on the Mac's screen, for the laser pointer (PROTOCOL.md 10, `in.laser`).
 *
 * Input is the Android game rotation vector as a quaternion (x, y, z, w): no magnetometer, so no drift toward north and
 * no jumps near metal. The phone is held like a remote with its top edge pointing at the screen. The direction of that
 * edge (the device Y axis in world coordinates) gives a heading and a pitch; both are measured from where the phone
 * pointed when the button went down, so the spot starts in the middle and "pointing the same way" always means the same spot.
 *
 * The output is smoothed with a One Euro filter: very steady when the hand is nearly still, quick when it moves.
 */
class LaserMapper(
    /** How far the phone turns, left to right and top to bottom, to cross the whole screen. */
    private val fovXDeg: Double = 36.0,
    private val fovYDeg: Double = 22.0,
    minCutoffHz: Double = 1.6,
    beta: Double = 1.2,
) {
    private val fx = OneEuro(minCutoffHz, beta)
    private val fy = OneEuro(minCutoffHz, beta)
    private var refHeading = 0.0
    private var refPitch = 0.0
    private var haveRef = false
    private var lastHeading = 0.0

    /** The next sample becomes the centre. Call when the button goes down. */
    fun recenter() {
        haveRef = false
        fx.reset(); fy.reset()
    }

    class Point(val x: Double, val y: Double)

    /** [t] in milliseconds. Returns the smoothed point, always within 0..1. */
    fun update(qx: Double, qy: Double, qz: Double, qw: Double, t: Long): Point {
        // The device Y axis (towards the top edge) in world coordinates: column 1 of the rotation matrix.
        val px = 2 * (qx * qy - qz * qw)
        val py = 1 - 2 * (qx * qx + qz * qz)
        val pz = 2 * (qy * qz + qx * qw)
        val pitch = asin(pz.coerceIn(-1.0, 1.0))
        // Pointing nearly straight up or down, the heading is meaningless; keep the last good one.
        val heading = if (hypot(px, py) < 0.17) lastHeading else atan2(px, py)
        lastHeading = heading
        if (!haveRef) {
            haveRef = true
            refHeading = heading; refPitch = pitch
            fx.reset(); fy.reset()
        }
        val fovX = Math.toRadians(fovXDeg)
        val fovY = Math.toRadians(fovYDeg)
        val rawX = 0.5 + wrap(heading - refHeading) / fovX
        val rawY = 0.5 - (pitch - refPitch) / fovY
        return Point(fx.filter(rawX.coerceIn(-0.25, 1.25), t).coerceIn(0.0, 1.0), fy.filter(rawY.coerceIn(-0.25, 1.25), t).coerceIn(0.0, 1.0))
    }

    private fun wrap(a: Double): Double {
        var x = a
        while (x > PI) x -= 2 * PI
        while (x < -PI) x += 2 * PI
        return x
    }

    /** One Euro filter (Casiez et al. 2012): a low-pass whose cutoff rises with speed. */
    private class OneEuro(private val minCutoff: Double, private val beta: Double, private val dCutoff: Double = 1.0) {
        private var x = 0.0
        private var dx = 0.0
        private var t = 0L
        private var has = false

        fun reset() { has = false }

        private fun alpha(cutoff: Double, dtS: Double): Double {
            val tau = 1.0 / (2 * PI * cutoff)
            return 1.0 / (1.0 + tau / dtS)
        }

        fun filter(v: Double, now: Long): Double {
            if (!has) { has = true; x = v; dx = 0.0; t = now; return v }
            val dtS = ((now - t).coerceAtLeast(1)) / 1000.0
            t = now
            val rawD = (v - x) / dtS
            dx += alpha(dCutoff, dtS) * (rawD - dx)
            val cutoff = minCutoff + beta * abs(dx)
            x += alpha(cutoff, dtS) * (v - x)
            return x
        }
    }
}

/** At most [maxPerSecond] `in.laser` updates, and none that are barely different from the last one sent. */
class LaserThrottle(private val maxPerSecond: Int = 60, private val epsilon: Double = 0.0015) {
    private var lastT = Long.MIN_VALUE / 2
    private var lastX = -1.0
    private var lastY = -1.0

    fun reset() { lastT = Long.MIN_VALUE / 2; lastX = -1.0; lastY = -1.0 }

    /** True if this point should be sent now. */
    fun allow(x: Double, y: Double, t: Long): Boolean {
        if (t - lastT < 1000L / maxPerSecond + 1) return false
        if (abs(x - lastX) < epsilon && abs(y - lastY) < epsilon) return false
        lastT = t; lastX = x; lastY = y
        return true
    }
}

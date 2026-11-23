package com.mydroid.protocol

import org.junit.Assert.*
import org.junit.Test
import kotlin.math.*

class LaserTest {
    /** Unit quaternion (x, y, z, w) for a rotation of [deg] about the unit axis. */
    private fun q(ax: Double, ay: Double, az: Double, deg: Double): DoubleArray {
        val h = Math.toRadians(deg) / 2
        val n = sqrt(ax * ax + ay * ay + az * az)
        return doubleArrayOf(ax / n * sin(h), ay / n * sin(h), az / n * sin(h), cos(h))
    }
    private fun mul(a: DoubleArray, b: DoubleArray): DoubleArray {
        val (x1, y1, z1, w1) = a; val (x2, y2, z2, w2) = b
        return doubleArrayOf(
            w1 * x2 + x1 * w2 + y1 * z2 - z1 * y2, w1 * y2 - x1 * z2 + y1 * w2 + z1 * x2,
            w1 * z2 + x1 * y2 - y1 * x2 + z1 * w2, w1 * w2 - x1 * x2 - y1 * y2 - z1 * z2,
        )
    }
    private operator fun DoubleArray.component4() = this[3]

    /** Phone pointing at the screen with its top edge, turned [yawDeg] to the right and tilted [pitchDeg] up. */
    private fun pose(yawDeg: Double, pitchDeg: Double): DoubleArray {
        val pitchUp = q(1.0, 0.0, 0.0, pitchDeg)    // rotate about world X: the +Y axis tips up
        val yawRight = q(0.0, 0.0, 1.0, -yawDeg)    // about world Z (up): negative angle turns clockwise from above
        return mul(yawRight, pitchUp)
    }
    private fun LaserMapper.at(p: DoubleArray, t: Long) = update(p[0], p[1], p[2], p[3], t)

    @Test fun firstSampleAfterRecenterIsTheMiddle() {
        val m = LaserMapper()
        val p = m.at(pose(73.0, 12.0), 0)
        assertEquals(0.5, p.x, 1e-9); assertEquals(0.5, p.y, 1e-9)
    }

    @Test fun turningRightMovesRightAndTiltingUpMovesUp() {
        val m = LaserMapper(minCutoffHz = 50.0, beta = 0.0)
        m.at(pose(0.0, 0.0), 0)
        var p = m.at(pose(10.0, 0.0), 20); p = m.at(pose(10.0, 0.0), 40)
        assertTrue("x=${p.x}", p.x > 0.6)
        assertEquals(0.5, p.y, 0.02)
        val u = LaserMapper(minCutoffHz = 50.0, beta = 0.0)
        u.at(pose(0.0, 0.0), 0)
        var a = u.at(pose(0.0, 6.0), 20); a = u.at(pose(0.0, 6.0), 40)
        assertTrue("y=${a.y}", a.y < 0.4)
        val l = LaserMapper(minCutoffHz = 50.0, beta = 0.0)
        l.at(pose(0.0, 0.0), 0)
        var b = l.at(pose(-10.0, 0.0), 20); b = l.at(pose(-10.0, 0.0), 40)
        assertTrue(b.x < 0.4)
    }

    @Test fun halfTheFieldOfViewReachesTheEdgeAndNeverLeavesTheScreen() {
        val m = LaserMapper(fovXDeg = 40.0, minCutoffHz = 100.0, beta = 0.0)
        m.at(pose(0.0, 0.0), 0)
        var p = m.at(pose(20.0, 0.0), 10); repeat(20) { p = m.at(pose(20.0, 0.0), 20L + it * 10) }
        assertEquals(1.0, p.x, 0.02)
        p = m.at(pose(90.0, 70.0), 500)
        assertTrue(p.x in 0.0..1.0 && p.y in 0.0..1.0)
    }

    @Test fun recenterMakesTheCurrentDirectionTheMiddleAgain() {
        val m = LaserMapper(minCutoffHz = 100.0, beta = 0.0)
        m.at(pose(0.0, 0.0), 0); m.at(pose(15.0, 0.0), 10)
        m.recenter()
        val p = m.at(pose(15.0, 0.0), 20)
        assertEquals(0.5, p.x, 1e-9)
    }

    @Test fun headingWrapsAroundWithoutJumping() {
        val m = LaserMapper(minCutoffHz = 100.0, beta = 0.0)
        m.at(pose(175.0, 0.0), 0)
        var p = m.at(pose(185.0, 0.0), 10); p = m.at(pose(185.0, 0.0), 40)
        assertTrue("x=${p.x}", p.x in 0.55..0.95) // 10 degrees to the right across the +-180 seam
    }

    @Test fun pointingStraightUpKeepsTheLastHeading() {
        val m = LaserMapper(minCutoffHz = 100.0, beta = 0.0)
        m.at(pose(30.0, 0.0), 0)
        val p = m.at(pose(30.0, 89.5), 10)
        assertTrue(p.x in 0.0..1.0)
        assertEquals(0.5, p.x, 0.05)
    }

    @Test fun smoothingCutsJitterButFollowsRealMovement() {
        val rnd = java.util.Random(7)
        val raw = ArrayList<Double>(); val smooth = ArrayList<Double>()
        val m = LaserMapper()
        val noisy = LaserMapper(minCutoffHz = 1000.0, beta = 0.0) // effectively no filtering
        m.at(pose(0.0, 0.0), 0); noisy.at(pose(0.0, 0.0), 0)
        for (i in 1..200) { // hand tremor of about +-0.4 degrees at 60 Hz
            val jitter = (rnd.nextDouble() - 0.5) * 0.8
            val t = i * 16L
            raw += noisy.at(pose(jitter, 0.0), t).x; smooth += m.at(pose(jitter, 0.0), t).x
        }
        fun sd(v: List<Double>) = sqrt(v.map { (it - v.average()).pow(2) }.average())
        assertTrue("raw=${sd(raw)} smooth=${sd(smooth)}", sd(smooth) < sd(raw) * 0.5)

        // a deliberate sweep of 15 degrees in a third of a second is followed closely
        val f = LaserMapper(); f.at(pose(0.0, 0.0), 0)
        var last = 0.0
        for (i in 1..20) last = f.at(pose(15.0 * i / 20, 0.0), i * 16L).x
        val target = 0.5 + Math.toRadians(15.0) / Math.toRadians(36.0)
        assertTrue("last=$last target=$target", abs(min(target, 1.0) - last) < 0.2)
    }

    @Test fun throttleCapsRateAndSkipsStillSamples() {
        val t = LaserThrottle()
        var sent = 0
        for (i in 0..999) if (t.allow(0.1 + i * 0.0005, 0.5, i.toLong())) sent++
        assertTrue("sent=$sent", sent in 30..60)
        val s = LaserThrottle()
        assertTrue(s.allow(0.5, 0.5, 0)); assertFalse(s.allow(0.5, 0.5, 100)); assertTrue(s.allow(0.6, 0.5, 200))
    }
}

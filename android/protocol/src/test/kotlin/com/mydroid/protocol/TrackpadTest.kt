package com.mydroid.protocol

import org.junit.Assert.*
import org.junit.Test
import kotlin.math.hypot
import kotlin.math.sin
import kotlin.math.cos

class TrackpadTest {
    class Ev(val t: Long, val kind: String, val dx: Double = 0.0, val dy: Double = 0.0, val phase: String? = null, val count: Int = 0)

    private class Rig(cfg: TrackpadConfig = TrackpadConfig()) {
        var now = 0L
        val ev = ArrayList<Ev>()
        var haptics = 0
        val sink = object : PointerSink {
            override fun move(dx: Double, dy: Double) { ev += Ev(now, "move", dx, dy) }
            override fun scroll(dx: Double, dy: Double, phase: String) { ev += Ev(now, "scroll", dx, dy, phase) }
            override fun click(button: String, count: Int) { ev += Ev(now, "click-$button", count = count) }
            override fun down(button: String) { ev += Ev(now, "down") }
            override fun up(button: String) { ev += Ev(now, "up") }
        }
        val engine = TrackpadEngine(sink, cfg, haptic = { haptics++ })

        fun at(t: Long, vararg f: Finger) { now = t; engine.touch(t, f.toList()) }
        fun tickTo(t: Long, step: Long = 4) { while (now < t) { now = minOf(now + step, t); engine.tick(now) } }
        fun kinds() = ev.map { it.kind }
        fun sumMove() = ev.filter { it.kind == "move" }.let { m -> m.sumOf { it.dx } to m.sumOf { it.dy } }
    }

    private fun f(id: Long, x: Double, y: Double) = Finger(id, x, y)

    // ---------------------------------------------------------------- acceleration

    @Test fun fasterFingerTravelsFartherOnTheMac() {
        val cfg = TrackpadConfig()
        assertTrue(cfg.gain(0.0) < cfg.gain(300.0))
        assertTrue(cfg.gain(300.0) < cfg.gain(1200.0))
        assertEquals(cfg.accelMax, cfg.gain(100_000.0), 0.0)
        assertTrue("slow movement stays precise", cfg.gain(20.0) < 1.5)

        fun travel(dpPerS: Double): Double {
            val r = Rig(); val step = 8L
            r.at(0, f(1, 100.0, 100.0))
            var x = 100.0
            var t = 0L
            while (t < 400) { t += step; x += dpPerS * step / 1000.0; r.at(t, f(1, x, 100.0)) }
            r.tickTo(t + 20)
            return r.sumMove().first / (x - 100.0)
        }
        val slow = travel(60.0)
        val fast = travel(900.0)
        assertTrue("slow=$slow fast=$fast", fast > slow * 2)
    }

    @Test fun cursorFollowsTheFingerDirection() {
        val r = Rig()
        r.at(0, f(1, 50.0, 50.0)); r.at(8, f(1, 50.0, 80.0)); r.at(16, f(1, 20.0, 80.0)); r.tickTo(40)
        val (dx, dy) = r.sumMove()
        assertTrue(dx < 0); assertTrue(dy > 0)
    }

    // ---------------------------------------------------------------- coalescing

    @Test fun movesNeverExceed120PerSecondAndNothingIsLost() {
        val cfg = TrackpadConfig(accelBase = 1.0, accelSlope = 0.0, accelMax = 1.0)
        val r = Rig(cfg)
        r.at(0, f(1, 0.0, 0.0))
        var x = 0.0
        for (t in 1L..2000L) { x += 0.4; r.at(t, f(1, x, 0.0)) } // 1 kHz touch events, 400 dp/s
        r.tickTo(2020)
        val times = r.ev.filter { it.kind == "move" }.map { it.t }
        assertTrue("sent ${times.size}", times.size > 100)
        for (i in times.indices) {
            val inWindow = times.count { it >= times[i] && it < times[i] + 1000 }
            assertTrue("window at ${times[i]} has $inWindow", inWindow <= 120)
        }
        assertEquals(x, r.sumMove().first, 0.5) // all of it arrives, gain 1.0
    }

    @Test fun scrollNeverExceeds60PerSecond() {
        val r = Rig()
        r.at(0, f(1, 10.0, 0.0), f(2, 60.0, 0.0))
        var y = 0.0
        for (t in 1L..1500L) { y += 0.3; r.at(t, f(1, 10.0, y), f(2, 60.0, y)) }
        r.at(1501)
        r.tickTo(1600)
        val times = r.ev.filter { it.kind == "scroll" }.map { it.t }
        for (i in times.indices) assertTrue(times.count { it >= times[i] && it < times[i] + 1000 } <= 60)
        assertEquals("began", r.ev.first { it.kind == "scroll" }.phase)
    }

    // ---------------------------------------------------------------- tap and click

    @Test fun quickTapClicksAndSlowTapDoesNot() {
        val r = Rig()
        r.at(0, f(1, 10.0, 10.0)); r.at(120, f(1, 11.0, 10.0)); r.at(130)
        assertEquals(listOf("click-left"), r.kinds())
        assertEquals(1, r.ev[0].count); assertEquals(1, r.haptics)
        val s = Rig()
        s.at(0, f(1, 10.0, 10.0)); s.at(300, f(1, 10.0, 10.0)); s.at(310)
        assertFalse(s.kinds().contains("click-left"))
    }

    @Test fun secondQuickTapIsADoubleClickAndThirdStartsOver() {
        val r = Rig()
        r.at(0, f(1, 10.0, 10.0)); r.at(60); r.at(200, f(1, 12.0, 10.0)); r.at(260)
        r.at(400, f(1, 10.0, 10.0)); r.at(450)
        assertEquals(listOf(1, 2, 1), r.ev.map { it.count })
    }

    @Test fun movingFingerNeverClicks() {
        val r = Rig()
        r.at(0, f(1, 10.0, 10.0)); r.at(40, f(1, 40.0, 10.0)); r.at(80); r.tickTo(120)
        assertFalse(r.kinds().any { it.startsWith("click") })
    }

    @Test fun twoFingerTapIsARightClick() {
        val r = Rig()
        r.at(0, f(1, 10.0, 10.0)); r.at(30, f(1, 10.0, 10.0), f(2, 60.0, 10.0)); r.at(120, f(2, 60.0, 10.0)); r.at(130)
        assertEquals(listOf("click-right"), r.kinds())
        assertEquals(1, r.haptics)
    }

    @Test fun twoFingerTapThatWasADragIsNotAClick() {
        val r = Rig()
        r.at(0, f(1, 10.0, 10.0), f(2, 60.0, 10.0)); r.at(60, f(1, 40.0, 10.0), f(2, 90.0, 10.0)); r.at(100); r.tickTo(200)
        assertFalse(r.kinds().contains("click-right"))
    }

    // ---------------------------------------------------------------- hold and drag

    @Test fun holdThenMoveDragsWithDownThenMovesThenUp() {
        val r = Rig()
        r.at(0, f(1, 100.0, 100.0))
        r.tickTo(500)
        assertEquals(listOf("down"), r.kinds())
        assertEquals(1, r.haptics)
        r.at(520, f(1, 120.0, 100.0)); r.at(540, f(1, 160.0, 110.0)); r.at(560)
        r.tickTo(600)
        assertEquals("down", r.kinds().first()); assertEquals("up", r.kinds().last())
        assertTrue(r.kinds().drop(1).dropLast(1).all { it == "move" } && r.kinds().size > 3)
        // the last bit of movement is delivered before the button is released
        assertTrue(r.ev.last().t >= r.ev.last { it.kind == "move" }.t)
    }

    @Test fun cancelReleasesAHeldButton() {
        val r = Rig()
        r.at(0, f(1, 5.0, 5.0)); r.tickTo(500)
        r.engine.cancel(510)
        assertEquals(listOf("down", "up"), r.kinds())
    }

    @Test fun movingBeforeTheHoldCancelsTheDrag() {
        val r = Rig()
        r.at(0, f(1, 5.0, 5.0)); r.at(100, f(1, 60.0, 5.0)); r.tickTo(700)
        assertFalse(r.kinds().contains("down"))
    }

    // ---------------------------------------------------------------- scroll and momentum

    @Test fun twoFingerSlideScrollsAndStaysPutWhenPausedBeforeLifting() {
        val r = Rig()
        r.at(0, f(1, 10.0, 100.0), f(2, 60.0, 100.0))
        r.at(30, f(1, 10.0, 110.0), f(2, 60.0, 110.0)); r.at(60, f(1, 10.0, 130.0), f(2, 60.0, 130.0))
        r.at(300, f(1, 10.0, 130.0), f(2, 60.0, 130.0)) // rested
        r.at(310, f(2, 60.0, 130.0))
        r.tickTo(500)
        val sc = r.ev.filter { it.kind == "scroll" }
        assertEquals("began", sc.first().phase); assertEquals("ended", sc.last().phase)
        assertEquals(30 * 2.5, sc.sumOf { it.dy }, 0.01)
        assertTrue(sc.none { it.phase == "momentum" })
        assertTrue(r.kinds().none { it.startsWith("click") })
    }

    @Test fun flickKeepsGoingWithDecayingMomentum() {
        val r = Rig()
        r.at(0, f(1, 10.0, 300.0), f(2, 60.0, 300.0))
        var y = 300.0
        var t = 0L
        while (t < 120) { t += 8; y -= 8.0; r.at(t, f(1, 10.0, y), f(2, 60.0, y)) } // 1000 dp/s upward
        r.at(t + 4, f(2, 60.0, y)); // lift
        r.tickTo(t + 2500)
        val mom = r.ev.filter { it.phase == "momentum" }
        assertTrue("momentum events: ${mom.size}", mom.size > 10)
        assertTrue(mom.all { it.dy < 0 })
        // decays: later momentum steps are smaller than early ones, and it ends by itself
        assertTrue(kotlin.math.abs(mom[mom.size - 1].dy) < kotlin.math.abs(mom[1].dy))
        assertFalse(r.engine.active)
        assertEquals("ended", r.ev.first { it.kind == "scroll" && it.phase == "ended" }.phase)
        assertTrue("ended comes before momentum", r.ev.indexOfFirst { it.phase == "ended" } < r.ev.indexOfFirst { it.phase == "momentum" })
        // total momentum distance is about v * tau
        val v = 1000.0 * 2.5
        assertEquals(v * 0.32, -mom.sumOf { it.dy }, v * 0.32 * 0.25)
        val times = mom.map { it.t }
        for (i in times.indices) assertTrue(times.count { it >= times[i] && it < times[i] + 1000 } <= 60)
    }

    @Test fun touchingDuringMomentumStopsIt() {
        val r = Rig()
        r.at(0, f(1, 10.0, 300.0), f(2, 60.0, 300.0))
        var y = 300.0; var t = 0L
        while (t < 120) { t += 8; y -= 8.0; r.at(t, f(1, 10.0, y), f(2, 60.0, y)) }
        r.at(t + 4); r.tickTo(t + 200)
        val n = r.ev.count { it.phase == "momentum" }
        assertTrue(n > 0)
        r.at(r.now + 1, f(1, 5.0, 5.0)); r.tickTo(r.now + 600)
        assertEquals(n, r.ev.count { it.phase == "momentum" })
    }

    @Test fun fingerLiftingAfterTwoFingerGestureDoesNotJumpTheCursor() {
        val r = Rig()
        r.at(0, f(1, 10.0, 100.0), f(2, 60.0, 100.0)); r.at(100, f(1, 10.0, 160.0), f(2, 60.0, 160.0))
        r.at(110, f(2, 60.0, 160.0)) // one finger lifts, the other lingers and wiggles
        r.at(140, f(2, 90.0, 190.0)); r.at(170, f(2, 120.0, 220.0)); r.at(180); r.tickTo(300)
        assertTrue(r.ev.none { it.kind == "move" })
    }

    @Test fun engineGoesIdleAfterTheGesture() {
        val r = Rig()
        r.at(0, f(1, 0.0, 0.0)); r.at(10, f(1, 30.0, 0.0)); r.at(20); r.tickTo(60)
        assertFalse(r.engine.active)
    }
}

package com.mydroid.protocol

import kotlin.math.exp
import kotlin.math.hypot
import kotlin.math.min

/** A finger on the touch surface. [x] and [y] are in dp (so gestures feel the same on every screen density). */
data class Finger(val id: Long, val x: Double, val y: Double)

/** What the trackpad does to the Mac. [RemoteSender] turns these into `in.*` messages. */
interface PointerSink {
    fun move(dx: Double, dy: Double)
    fun scroll(dx: Double, dy: Double, phase: String)
    fun click(button: String, count: Int)
    fun down(button: String)
    fun up(button: String)
}

class TrackpadConfig(
    /** A touch that stays inside this radius is a tap, not a move. */
    val slopDp: Double = 6.0,
    val tapMaxMs: Long = 250,
    val doubleTapMs: Long = 320,
    val doubleTapSlopDp: Double = 40.0,
    /** Hold still this long, then move, to drag (`in.down` ... `in.up`). */
    val holdMs: Long = 450,
    val twoFingerTapMs: Long = 400,
    /** 9 ms between messages: at most 111 per second, under the protocol's 120. */
    val moveIntervalMs: Long = 9,
    /** 17 ms: at most 58 per second, under the protocol's 60. */
    val scrollIntervalMs: Long = 17,
    /** Pointer acceleration: Mac points per dp of finger travel is `base + slope * speed (dp/s)`, capped at [accelMax]. */
    val accelBase: Double = 1.25,
    val accelSlope: Double = 0.0032,
    val accelMax: Double = 5.5,
    val speedSmoothing: Double = 0.4,
    /** Scroll pixels per dp of two-finger travel. */
    val scrollGain: Double = 2.5,
    val scrollSlopDp: Double = 5.0,
    val flingMinDpPerS: Double = 120.0,
    val velocityWindowMs: Long = 90,
    /** Momentum decays as exp(-t / tau). */
    val momentumTauMs: Double = 320.0,
    val momentumStopPxPerS: Double = 14.0,
) {
    fun gain(speedDpPerS: Double): Double = min(accelMax, accelBase + accelSlope * speedDpPerS)
}

/**
 * Touch gestures to Mac pointer events, as a pure state machine so the feel can be tested without a phone.
 * Feed it [touch] with the fingers currently down on every pointer event and call [tick] while [active] is true
 * (a frame loop is enough). All times are milliseconds on one clock.
 *
 * - One finger moves the cursor with velocity-based acceleration; a quick tap clicks (a second quick tap is a double click).
 * - Hold one finger still, then move: drag (`down`, moves, `up`).
 * - Two fingers: a quick tap right-clicks; moving scrolls, and a flick keeps going with decaying `momentum`.
 * - Moves go out at most every [TrackpadConfig.moveIntervalMs], scrolls every [TrackpadConfig.scrollIntervalMs]; what arrives in
 *   between is summed and sent with the next message, so nothing is lost.
 */
class TrackpadEngine(
    private val out: PointerSink,
    private val cfg: TrackpadConfig = TrackpadConfig(),
    private val haptic: () -> Unit = {},
    /** Called when [active] may have turned true, so the caller can start its frame loop. */
    private val wake: () -> Unit = {},
) {
    private enum class Mode { Idle, Single, Drag, Multi, Ignore }

    private var mode = Mode.Idle

    // one finger
    private var activeId = -1L
    private var downT = 0L
    private var downX = 0.0
    private var downY = 0.0
    private var lastX = 0.0
    private var lastY = 0.0
    private var lastT = 0L
    private var moved = false
    private var speed = 0.0
    private var lastTapT = Long.MIN_VALUE / 2
    private var lastTapX = 0.0
    private var lastTapY = 0.0

    // pending cursor movement
    private var pdx = 0.0
    private var pdy = 0.0
    private var lastMoveSent = Long.MIN_VALUE / 2
    private var releaseQueued = false

    // two fingers
    private var multiT0 = 0L
    private var rightEligible = false
    private var travelled = false
    private var scrolling = false
    private var scrollBegan = false
    private var startPos = HashMap<Long, Pair<Double, Double>>()
    private var startCx = 0.0
    private var startCy = 0.0
    private var lastCx = 0.0
    private var lastCy = 0.0
    private val samples = ArrayDeque<Triple<Long, Double, Double>>()
    private var sdx = 0.0
    private var sdy = 0.0
    private var lastScrollSent = Long.MIN_VALUE / 2
    private var scrollEnding = false
    private var endFlingVx = 0.0
    private var endFlingVy = 0.0

    // momentum
    private var momActive = false
    private var momVx = 0.0
    private var momVy = 0.0
    private var momLastT = 0L

    /** True while a frame loop calling [tick] is needed: a hold may start, residue is waiting, or momentum is running. */
    val active: Boolean
        get() = (mode == Mode.Single && !moved) || pdx != 0.0 || pdy != 0.0 || releaseQueued ||
            sdx != 0.0 || sdy != 0.0 || scrollEnding || momActive

    val dragging: Boolean get() = mode == Mode.Drag

    // ---------------------------------------------------------------- input

    fun touch(now: Long, fingers: List<Finger>) {
        if (fingers.isNotEmpty()) momActive = false // a touch stops the glide before anything else happens
        tick(now)
        if (fingers.isNotEmpty()) {
            if (releaseQueued) { releaseQueued = false; flushMove(now, force = true); out.up("left") }
        }
        when (mode) {
            Mode.Idle -> when {
                fingers.size >= 2 -> startMulti(now, fingers, fromSingle = false)
                fingers.size == 1 -> startSingle(now, fingers[0])
            }
            Mode.Single -> single(now, fingers)
            Mode.Drag -> drag(now, fingers)
            Mode.Multi -> multi(now, fingers)
            Mode.Ignore -> if (fingers.isEmpty()) mode = Mode.Idle
        }
        if (active) wake()
    }

    /** Run residual flushes, the hold timer and momentum. Cheap; safe to call at any rate. */
    fun tick(now: Long) {
        if (mode == Mode.Single && !moved && now - downT >= cfg.holdMs) {
            mode = Mode.Drag
            haptic()
            out.down("left")
        }
        if (!releaseQueued) flushMove(now, force = false)
        tryRelease(now)
        if (mode == Mode.Multi) flushScroll(now)
        finishScrollIfDue(now)
        runMomentum(now)
    }

    /** The screen is going away: never leave the Mac with a button held or a scroll half done. */
    fun cancel(now: Long) {
        if (mode == Mode.Drag || releaseQueued) { releaseQueued = false; flushMove(now, force = true); out.up("left") }
        if (scrolling || scrollEnding) { out.scroll(sdx, sdy, "ended"); scrolling = false; scrollEnding = false }
        pdx = 0.0; pdy = 0.0; sdx = 0.0; sdy = 0.0
        momActive = false
        moved = false
        mode = Mode.Idle
    }

    // ---------------------------------------------------------------- one finger

    private fun startSingle(now: Long, f: Finger) {
        mode = Mode.Single
        activeId = f.id
        downT = now; downX = f.x; downY = f.y
        lastX = f.x; lastY = f.y; lastT = now
        moved = false
        speed = 0.0
    }

    private fun single(now: Long, fingers: List<Finger>) {
        if (fingers.isEmpty()) { endSingle(now); return }
        if (fingers.size >= 2) { startMulti(now, fingers, fromSingle = true); return }
        val f = fingers[0]
        if (f.id != activeId) { activeId = f.id; lastX = f.x; lastY = f.y; lastT = now; return }
        if (!moved) {
            if (hypot(f.x - downX, f.y - downY) <= cfg.slopDp) return
            moved = true
            lastX = downX; lastY = downY; lastT = downT
        }
        applyMove(now, f)
    }

    private fun endSingle(now: Long) {
        mode = Mode.Idle
        if (moved || now - downT > cfg.tapMaxMs) return
        val dbl = now - lastTapT <= cfg.doubleTapMs && hypot(downX - lastTapX, downY - lastTapY) <= cfg.doubleTapSlopDp
        haptic()
        out.click("left", if (dbl) 2 else 1)
        if (dbl) lastTapT = Long.MIN_VALUE / 2 else { lastTapT = now; lastTapX = downX; lastTapY = downY }
    }

    private fun drag(now: Long, fingers: List<Finger>) {
        val f = fingers.firstOrNull { it.id == activeId }
        if (f == null) {
            releaseQueued = true
            tryRelease(now)
            mode = if (fingers.isEmpty()) Mode.Idle else Mode.Ignore
            return
        }
        applyMove(now, f)
    }

    private fun applyMove(now: Long, f: Finger) {
        val dx = f.x - lastX
        val dy = f.y - lastY
        val dt = (now - lastT).coerceIn(1, 60)
        val inst = hypot(dx, dy) / dt * 1000.0
        speed += (inst - speed) * cfg.speedSmoothing
        val g = cfg.gain(speed)
        pdx += dx * g; pdy += dy * g
        lastX = f.x; lastY = f.y; lastT = now
        flushMove(now, force = false)
    }

    private fun flushMove(now: Long, force: Boolean) {
        if (pdx == 0.0 && pdy == 0.0) return
        if (!force && now - lastMoveSent < cfg.moveIntervalMs) return
        out.move(pdx, pdy)
        pdx = 0.0; pdy = 0.0
        lastMoveSent = now
    }

    /** `in.up` waits for the last bit of movement, which in turn waits for the rate limit, so the drop lands where the finger left. */
    private fun tryRelease(now: Long) {
        if (!releaseQueued) return
        if ((pdx != 0.0 || pdy != 0.0) && now - lastMoveSent < cfg.moveIntervalMs) return
        flushMove(now, force = true)
        out.up("left")
        releaseQueued = false
    }

    // ---------------------------------------------------------------- two fingers

    private fun two(fingers: List<Finger>) = fingers.sortedBy { it.id }.take(2)

    private fun startMulti(now: Long, fingers: List<Finger>, fromSingle: Boolean) {
        mode = Mode.Multi
        val f = two(fingers)
        startPos = HashMap(f.associate { it.id to (it.x to it.y) })
        startCx = f.sumOf { it.x } / f.size; startCy = f.sumOf { it.y } / f.size
        lastCx = startCx; lastCy = startCy
        multiT0 = if (fromSingle && !moved) downT else now
        rightEligible = !fromSingle || !moved
        travelled = false
        scrolling = false; scrollBegan = false
        sdx = 0.0; sdy = 0.0
        samples.clear()
    }

    private fun multi(now: Long, fingers: List<Finger>) {
        if (fingers.size < 2) {
            endMulti(now)
            mode = if (fingers.isEmpty()) Mode.Idle else Mode.Ignore
            return
        }
        val f = two(fingers)
        for (p in f) {
            val s = startPos[p.id] ?: continue
            if (hypot(p.x - s.first, p.y - s.second) > cfg.slopDp * 1.5) travelled = true
        }
        val cx = f.sumOf { it.x } / f.size
        val cy = f.sumOf { it.y } / f.size
        if (!scrolling) {
            if (hypot(cx - startCx, cy - startCy) <= cfg.scrollSlopDp) return
            scrolling = true
            lastCx = startCx; lastCy = startCy
        }
        sdx += (cx - lastCx) * cfg.scrollGain
        sdy += (cy - lastCy) * cfg.scrollGain
        lastCx = cx; lastCy = cy
        samples.addLast(Triple(now, cx, cy))
        while (samples.size > 2 && now - samples.first().first > cfg.velocityWindowMs) samples.removeFirst()
        flushScroll(now)
    }

    private fun endMulti(now: Long) {
        if (!scrolling) {
            if (rightEligible && !travelled && now - multiT0 <= cfg.twoFingerTapMs) {
                haptic()
                out.click("right", 1)
            }
            return
        }
        scrolling = false
        // Velocity over the last moments of the gesture; a finger that rested before lifting does not fling.
        var vx = 0.0
        var vy = 0.0
        val last = samples.lastOrNull()
        val first = samples.firstOrNull()
        if (last != null && first != null && last !== first && now - last.first <= 60 && last.first - first.first >= 10) {
            val dt = (last.first - first.first) / 1000.0
            vx = (last.second - first.second) / dt * cfg.scrollGain
            vy = (last.third - first.third) / dt * cfg.scrollGain
        }
        val fling = hypot(vx, vy) >= cfg.flingMinDpPerS * cfg.scrollGain
        endFlingVx = if (fling) vx else 0.0
        endFlingVy = if (fling) vy else 0.0
        scrollEnding = true
        samples.clear()
        finishScrollIfDue(now)
    }

    private fun flushScroll(now: Long) {
        if (sdx == 0.0 && sdy == 0.0) return
        if (now - lastScrollSent < cfg.scrollIntervalMs) return
        out.scroll(sdx, sdy, if (!scrollBegan) "began" else "changed")
        scrollBegan = true
        sdx = 0.0; sdy = 0.0
        lastScrollSent = now
    }

    /** `ended` carries whatever movement was still waiting, so it is one message. Momentum starts right after it. */
    private fun finishScrollIfDue(now: Long) {
        if (!scrollEnding || now - lastScrollSent < cfg.scrollIntervalMs) return
        out.scroll(sdx, sdy, "ended")
        sdx = 0.0; sdy = 0.0
        scrollEnding = false
        scrollBegan = false
        lastScrollSent = now
        if (endFlingVx != 0.0 || endFlingVy != 0.0) {
            momVx = endFlingVx; momVy = endFlingVy
            momLastT = now
            momActive = true
        }
    }

    private fun runMomentum(now: Long) {
        if (!momActive) return
        val dt = now - momLastT
        if (dt < cfg.scrollIntervalMs) return
        val k = exp(-dt / cfg.momentumTauMs)
        val span = cfg.momentumTauMs / 1000.0 * (1 - k)
        out.scroll(momVx * span, momVy * span, "momentum")
        momVx *= k; momVy *= k
        momLastT = now
        lastScrollSent = now
        if (hypot(momVx, momVy) < cfg.momentumStopPxPerS) momActive = false
    }
}

/** Pointer events as `in.*` messages. */
class RemoteSender(private val send: (Message) -> Unit) : PointerSink {
    override fun move(dx: Double, dy: Double) = send(RemoteWire.move(dx, dy))
    override fun scroll(dx: Double, dy: Double, phase: String) = send(RemoteWire.scroll(dx, dy, phase))
    override fun click(button: String, count: Int) = send(RemoteWire.click(button, count))
    override fun down(button: String) = send(RemoteWire.down(button))
    override fun up(button: String) = send(RemoteWire.up(button))
}

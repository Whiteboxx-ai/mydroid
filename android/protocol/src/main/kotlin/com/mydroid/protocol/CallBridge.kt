package com.mydroid.protocol

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.SocketException
import java.net.SocketTimeoutException
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.locks.LockSupport

/** Where call audio comes from. [read] fills the buffer or returns a negative error; [stop] unblocks a pending read. */
interface PcmSource {
    fun read(buf: ByteArray, off: Int, len: Int): Int
    fun stop()
    fun release()
}

/** Where Mac audio goes. [write] blocks until accepted and returns bytes written or a negative error. */
interface PcmSink {
    fun write(buf: ByteArray, off: Int, len: Int): Int
    fun release()
}

/** The Android side of the helper (AudioManager reflection and AudioRecord/AudioTrack). Faked in the JVM tests. */
interface CallAudioBackend {
    /** Cheap, safe outside a call. `Full` here is provisional: it is only proven when a call lets us create both ends. */
    fun probeTier(): CallTier
    /** `AudioManager.getMode() == MODE_IN_CALL`. */
    fun inCall(): Boolean
    /** [full] = `getCallDownlinkExtractionAudioRecord`, otherwise plain `VOICE_DOWNLINK` capture. Started. Throws on failure. */
    fun openDownlink(full: Boolean): PcmSource
    /** `getCallUplinkInjectionAudioTrack`, playing. Throws on failure. */
    fun openUplink(): PcmSink
}

/**
 * The helper's brain: routes call audio to the Mac over encrypted UDP and Mac audio back into the call.
 * Threads: the caller of [handleLine] (stdin), a call-mode watcher, and while routed a downlink reader, an uplink
 * receiver, an uplink writer and a stats ticker. Every failure turns into an event, never an exit.
 */
class CallBridge(
    private val backend: CallAudioBackend,
    private val emit: (String) -> Unit,
    private val log: (String) -> Unit = {},
    /** Run at the start of each audio thread (Main raises the priority). */
    private val audioThread: () -> Unit = {},
    private val pollMs: Long = 250,
    private val statsMs: Long = 1000,
    /** How long `route mac` waits for the call mode to show up before refusing. */
    private val callWaitMs: Long = 1500,
) {
    private val lock = Any()
    @Volatile private var closed = false
    private var tier = CallTier.None
    @Volatile private var inCall = false

    private var host: String? = null
    private var port = 0
    private var keys: AudioKeys? = null
    private var lastMaster: ByteArray? = null
    /** Nonce discipline: seq keeps counting across routes while the key is unchanged, so GCM never sees a repeat. */
    @Volatile private var downSeq = 0L

    private var route: Route? = null
    private var watcher: Thread? = null

    val routedToMac: Boolean get() = synchronized(lock) { route != null }

    fun start() {
        tier = try { backend.probeTier() } catch (t: Throwable) { log("probe failed: $t"); CallTier.None }
        inCall = try { backend.inCall() } catch (t: Throwable) { false }
        emit(HelperControl.tier(tier))
        emit(HelperControl.call(inCall))
        watcher = Thread({ watch() }, "callbridge-watch").apply { isDaemon = true; start() }
    }

    /** Returns false once the helper should exit. */
    fun handleLine(line: String): Boolean {
        if (line.isBlank()) return true
        try {
            when (val c = HelperControl.parse(line)) {
                is HelperCmd.Hello -> hello(c)
                is HelperCmd.Route -> if (c.toMac) routeToMac() else routeToPhone()
                HelperCmd.Quit -> { shutdown(); return false }
                is HelperCmd.Bad -> log("ignored command: ${c.reason}")
            }
        } catch (t: Throwable) {
            log("command failed: $t")
        }
        return true
    }

    fun shutdown() {
        closed = true
        val r = synchronized(lock) { route.also { route = null } }
        r?.stop()
        watcher?.interrupt()
    }

    // ---------------------------------------------------------------- commands

    private fun hello(c: HelperCmd.Hello) {
        synchronized(lock) {
            if (route != null) { log("hello ignored while routed"); return }
            if (lastMaster?.contentEquals(c.key) != true) downSeq = 0L
            lastMaster = c.key
            host = c.macHost; port = c.udpPort
            keys = AudioKeys(c.key)
        }
        log("hello accepted")
    }

    private fun routeToPhone() {
        val r = synchronized(lock) { route.also { route = null } }
        r?.stop()
        emit(HelperControl.routed("phone"))
    }

    private fun routeToMac() {
        synchronized(lock) { if (route != null) { emit(HelperControl.routed("mac")); return } }
        val deadline = System.currentTimeMillis() + callWaitMs
        var now = pollInCall()
        while (!now && System.currentTimeMillis() < deadline && !closed) { Thread.sleep(50); now = pollInCall() }
        if (!now) { emit(HelperControl.routed("mac", error = "not in a call")); return }
        setInCall(true) // the watcher may not have polled yet; a call that ends right after must still release the route
        synchronized(lock) {
            if (route != null) { emit(HelperControl.routed("mac")); return }
            val k = keys
            val h = host
            if (k == null || h == null) { emit(HelperControl.routed("mac", error = "no hello")); return }
            try {
                val r = openRoute(h, port, k)
                route = r
                emit(HelperControl.routed("mac"))
                log("routed to mac tier=${tier.wire}")
            } catch (t: Throwable) {
                log("route to mac failed: $t")
                emit(HelperControl.routed("mac", error = describe(t)))
            }
        }
    }

    private val callLock = Any()

    /** Records the call state and tells the Mac when it changed. */
    private fun setInCall(now: Boolean) {
        synchronized(callLock) {
            if (inCall == now) return
            inCall = now
            emit(HelperControl.call(now))
        }
    }

    private fun reprobe() {
        val t = try { backend.probeTier() } catch (e: Throwable) { CallTier.None }
        if (t != tier) { tier = t; emit(HelperControl.tier(t)) }
    }

    private fun pollInCall(): Boolean = try { backend.inCall() } catch (t: Throwable) { false }

    private fun describe(t: Throwable): String {
        val c = if (t is java.lang.reflect.InvocationTargetException) t.cause ?: t else t
        return (c.message ?: c.javaClass.simpleName).take(160)
    }

    /** Opens whatever the tier allows, downgrading honestly: full can fall back to listen, listen to none. */
    private fun openRoute(host: String, port: Int, keys: AudioKeys): Route {
        var source: PcmSource? = null
        var sink: PcmSink? = null
        var socket: DatagramSocket? = null
        try {
            if (tier == CallTier.None) reprobe() // outside a call the dry checks can be pessimistic; we're in one now
            var t = tier
            if (t == CallTier.None) throw IllegalStateException("call audio isn't available on this phone")
            if (t == CallTier.Full) {
                try {
                    source = backend.openDownlink(true)
                    try {
                        sink = backend.openUplink()
                    } catch (e: Throwable) {
                        log("uplink injection unavailable: ${describe(e)}")
                        t = CallTier.Listen // we still have the downlink
                    }
                } catch (e: Throwable) {
                    log("downlink extraction unavailable: ${describe(e)}")
                    t = CallTier.Listen
                }
            }
            if (source == null) {
                try {
                    source = backend.openDownlink(false)
                } catch (e: Throwable) {
                    tier = CallTier.None
                    emit(HelperControl.tier(tier))
                    throw IllegalStateException("couldn't capture call audio: ${describe(e)}")
                }
            }
            if (t != tier) { tier = t; emit(HelperControl.tier(tier)) }
            val addr = InetAddress.getByName(host)
            socket = DatagramSocket().apply {
                soTimeout = 500
                runCatching { trafficClass = 0xB8 } // EF: voice
            }
            val r = Route(source, sink, socket, addr, port, keys)
            r.start()
            return r
        } catch (t: Throwable) {
            runCatching { source?.stop() }; runCatching { source?.release() }
            runCatching { sink?.release() }
            runCatching { socket?.close() }
            throw t
        }
    }

    // ---------------------------------------------------------------- call mode watcher

    private fun watch() {
        var offPolls = 0
        while (!closed) {
            try { Thread.sleep(pollMs) } catch (e: InterruptedException) { return }
            val now = pollInCall()
            if (now == inCall) { offPolls = 0; continue }
            if (!now) {
                // Leaving a call needs two polls in a row, so a one-poll mode blip can't drop a routed call.
                if (++offPolls < 2) continue
            }
            offPolls = 0
            setInCall(now)
            if (now && tier == CallTier.None) reprobe()
            if (!now) {
                val r = synchronized(lock) { route.also { route = null } }
                if (r != null) { r.stop(); emit(HelperControl.routed("phone", reason = "call ended")); log("call ended, released") }
            }
        }
    }

    // ---------------------------------------------------------------- one routed call

    private class Level {
        private var sum = 0.0
        private var n = 0L
        @Synchronized fun add(frame: ByteArray) { sum += AudioFmt.rms(frame, 0, frame.size); n++ }
        @Synchronized fun takeRms(): Int { val v = if (n == 0L) 0 else Math.round(sum / n).toInt(); sum = 0.0; n = 0; return v }
    }

    private inner class Route(
        private val source: PcmSource,
        private val sink: PcmSink?,
        private val socket: DatagramSocket,
        private val addr: InetAddress,
        private val port: Int,
        keys: AudioKeys,
    ) {
        @Volatile private var running = true
        private val sealer = AudioSealer(keys.down)
        private val opener = AudioOpener(keys.up)
        private val replay = ReplayWindow()
        private val queue = PlayoutQueue()
        private val rx = Level()
        private val tx = Level()
        private val sent = AtomicLong()
        private val recv = AtomicLong()
        private val threads = ArrayList<Thread>()

        fun start() {
            threads += thread("callbridge-down") { downlinkLoop() }
            if (sink != null) {
                threads += thread("callbridge-up-recv") { uplinkReceiveLoop() }
                threads += thread("callbridge-up-write") { uplinkWriteLoop(sink) }
            }
            threads += thread("callbridge-stats") { statsLoop() }
        }

        private fun thread(name: String, body: () -> Unit) = Thread({
            try { if (name != "callbridge-stats") audioThread(); body() }
            catch (t: Throwable) { if (running) abort("audio stopped: ${describe(t)}") }
        }, name).apply { isDaemon = true; start() }

        /** Stop everything and wait briefly for the threads; safe to call twice and from any thread but our own. */
        fun stop() {
            if (!running) return
            running = false
            runCatching { socket.close() }
            runCatching { source.stop() }
            for (t in threads) if (t !== Thread.currentThread()) runCatching { t.interrupt(); t.join(1500) }
            runCatching { source.release() }
            runCatching { sink?.release() }
            queue.clear()
        }

        /** An audio error: go back to the phone (the call itself is untouched) and say why. */
        private fun abort(why: String) {
            val mine = synchronized(lock) { if (route === this) { route = null; true } else false }
            if (!mine) return
            log(why)
            Thread({ stop(); emit(HelperControl.routed("phone", error = why)) }, "callbridge-abort").apply { isDaemon = true; start() }
        }

        private fun downlinkLoop() {
            val buf = ByteArray(AudioFmt.FRAME_BYTES)
            var pos = 0
            val dp = DatagramPacket(ByteArray(0), 0, addr, port)
            while (running) {
                val n = source.read(buf, pos, buf.size - pos)
                if (n < 0) throw java.io.IOException("read failed ($n)")
                pos += n
                if (pos < buf.size) continue
                pos = 0
                rx.add(buf) // levels only. The frame goes straight into a packet; nothing is kept
                val seq = downSeq
                downSeq = (seq + 1) and 0xFFFF_FFFFL
                val pkt = sealer.seal(seq, buf)
                dp.setData(pkt, 0, pkt.size)
                try { socket.send(dp); sent.incrementAndGet() } catch (e: java.io.IOException) { if (running) log("send failed: ${e.javaClass.simpleName}") }
            }
        }

        private fun uplinkReceiveLoop() {
            val data = ByteArray(AudioFmt.PACKET_BYTES + 64)
            val dp = DatagramPacket(data, data.size)
            while (running) {
                try {
                    dp.setData(data, 0, data.size)
                    socket.receive(dp)
                } catch (e: SocketTimeoutException) {
                    continue
                } catch (e: SocketException) {
                    if (running) throw e else return
                }
                val p = opener.open(data, dp.length) ?: continue // forged, damaged or the wrong size
                if (!replay.accept(p.seq)) continue
                recv.incrementAndGet()
                queue.push(p.seq, p.frame)
            }
        }

        private fun uplinkWriteLoop(sink: PcmSink) {
            val silence = ByteArray(AudioFmt.FRAME_BYTES)
            val tick = AudioFmt.FRAME_MS * 1_000_000L
            // A 40 ms cushion in the track, then one frame per 20 ms. Writing faster would only grow latency.
            repeat(2) { sink.write(silence, 0, silence.size) }
            var next = System.nanoTime() + tick
            while (running) {
                val f = queue.pop()
                if (f != null) tx.add(f)
                val w = sink.write(f ?: silence, 0, AudioFmt.FRAME_BYTES)
                if (w < 0) throw java.io.IOException("write failed ($w)")
                next += tick
                val now = System.nanoTime()
                if (now - next > 3 * tick) next = now // fell behind (a stall): don't burst to catch up
                else if (next > now) LockSupport.parkNanos(next - now)
            }
        }

        private fun statsLoop() {
            while (running) {
                try { Thread.sleep(statsMs) } catch (e: InterruptedException) { return }
                if (!running) return
                emit(HelperControl.stats(rx.takeRms(), tx.takeRms(), queue.lost + queue.late, sent.get(), recv.get(), queue.underruns))
            }
        }
    }
}

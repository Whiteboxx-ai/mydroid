package com.mydroid.protocol

import kotlinx.serialization.json.put
import java.io.Closeable
import java.io.IOException
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicBoolean

interface SessionListener {
    /** Pairing only: both sides show this code. Raw digits, use [Keys.displayCode] to format. */
    fun onConfirmCode(code: String) {}

    /** Normal reconnect: after `welcome`. Pairing: after `pair.confirmed`. */
    fun onReady(pairing: Boolean, macName: String) {}
    fun onRejected() {}
    fun onUnpaired() {}

    /** Every other message (including `ping` after the automatic `pong`). Runs on the read thread. */
    fun onMessage(m: Message) {}
    fun onClosed(reason: String?) {}
}

enum class SessionState { AUTHENTICATING, AWAITING_CONFIRM, READY, CLOSED }

/**
 * Client side of an established [SecureChannel]: auth, welcome, pairing confirmation,
 * heartbeat (ping every 25 s screen-on, 90 s screen-off), automatic pong, bye/unpair handling.
 * The 240 s receive-idle drop comes from the channel's socket read timeout.
 */
class ClientSession(
    val channel: SecureChannel,
    private val identity: DeviceIdentity,
    val pairing: Boolean,
    private val listener: SessionListener,
    /** Current ping interval; re-read after every ping. */
    private val heartbeatMs: () -> Long = { Heartbeat.SCREEN_ON_MS },
) : Closeable {
    @Volatile
    var state = SessionState.AUTHENTICATING
        private set
    @Volatile
    var macName: String = ""
        private set
    private val closedOnce = AtomicBoolean(false)
    private var heartbeat: ScheduledExecutorService? = null
    private var nextPing: java.util.concurrent.ScheduledFuture<*>? = null
    private var pingGeneration = 0

    @Synchronized
    private fun scheduleNext(delayMs: Long = heartbeatMs()) {
        val ex = heartbeat ?: return
        if (state == SessionState.CLOSED || ex.isShutdown) return
        nextPing?.cancel(false)
        val generation = ++pingGeneration
        nextPing = ex.schedule({
            synchronized(this) {
                if (generation != pingGeneration || state == SessionState.CLOSED) return@schedule
            }
            try {
                channel.send(Message.of("ping"))
                synchronized(this) {
                    if (generation == pingGeneration) scheduleNext()
                }
            } catch (e: IOException) {
                channel.close()
            }
        }, delayMs, TimeUnit.MILLISECONDS)
    }

    /** Queue an immediate check after Android resumes network access. Never writes on the calling thread. */
    fun checkLiveness() = scheduleNext(delayMs = 0)

    @Synchronized
    private fun startHeartbeat() {
        heartbeat = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "mydroid-heartbeat").apply { isDaemon = true } }
        scheduleNext()
    }

    fun send(m: Message) = channel.send(m)

    /** Blocks on the read loop until the connection ends; always calls listener.onClosed exactly once. */
    fun run() {
        var reason: String? = null
        try {
            channel.send(
                Message.of("auth") {
                    put("name", identity.name); put("model", identity.model)
                    if (identity.androidSdk > 0) put("android", identity.androidSdk)
                },
            )
            startHeartbeat()
            loop@ while (true) {
                val m = channel.receive()
                when (m.type) {
                    "welcome" -> {
                        macName = m.str("name") ?: ""
                        if (pairing) {
                            state = SessionState.AWAITING_CONFIRM
                            listener.onConfirmCode(channel.confirmCode)
                        } else {
                            state = SessionState.READY
                            listener.onReady(false, macName)
                        }
                    }
                    "pair.confirmed" -> if (pairing) {
                        state = SessionState.READY
                        listener.onReady(true, macName)
                    }
                    "pair.rejected" -> {
                        listener.onRejected()
                        reason = "rejected"
                        break@loop
                    }
                    "ping" -> {
                        channel.send(Message.of("pong"))
                        listener.onMessage(m)
                    }
                    "pong" -> {}
                    "bye" -> {
                        reason = "bye"
                        break@loop
                    }
                    "unpair" -> {
                        listener.onUnpaired()
                        reason = "unpair"
                        break@loop
                    }
                    else -> listener.onMessage(m)
                }
            }
        } catch (e: Exception) {
            reason = e.message ?: e.javaClass.simpleName
        } finally {
            shutdown(reason)
        }
    }

    private fun shutdown(reason: String?) {
        synchronized(this) {
            state = SessionState.CLOSED
            heartbeat?.shutdownNow()
        }
        channel.close()
        if (closedOnce.compareAndSet(false, true)) listener.onClosed(reason)
    }

    /** Graceful: sends `bye` then closes. */
    fun sayGoodbye() {
        try {
            channel.send(Message.of("bye"))
        } catch (_: IOException) {
        }
        channel.close()
    }

    override fun close() = channel.close()
}

/**
 * Races connection attempts to several candidate addresses (Bonjour, last good, QR) in parallel.
 * The first attempt that returns wins; any later successes are closed.
 */
class CandidateRacer<T : Closeable>(private val attempt: (HostPort) -> T) {
    private val result = CompletableFuture<T>()
    private val seen = HashSet<HostPort>()
    private val pending = AtomicInteger(0)
    private val errors = java.util.concurrent.CopyOnWriteArrayList<String>()
    @Volatile private var cancelled = false

    fun add(hp: HostPort) {
        synchronized(seen) { if (cancelled || !seen.add(hp)) return }
        pending.incrementAndGet()
        Thread({
            try {
                val c = attempt(hp)
                if (!result.complete(c)) c.close()
            } catch (e: Exception) {
                errors += "$hp: ${e.message}"
            } finally {
                pending.decrementAndGet()
            }
        }, "mydroid-dial-$hp").apply { isDaemon = true }.start()
    }

    val isCancelled: Boolean get() = cancelled

    val lastErrors: List<String> get() = errors.toList()

    /** Waits up to [timeoutMs]; returns early with null once everything failed and [expectMore] is false. */
    fun await(timeoutMs: Long, expectMore: () -> Boolean = { false }): T? {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            try {
                return result.get(100, TimeUnit.MILLISECONDS)
            } catch (_: java.util.concurrent.TimeoutException) {
            } catch (_: java.util.concurrent.CancellationException) {
                return null
            }
            if (cancelled) return null
            if (pending.get() == 0 && synchronized(seen) { seen.isNotEmpty() } && !expectMore()) return null
        }
        return null
    }

    fun cancel() {
        cancelled = true
        if (!result.cancel(false)) runCatching { result.getNow(null)?.close() }
    }
}

/** 1s, 2s, 4s ... capped at 30s. */
class Backoff(private val capMs: Long = 30_000) {
    private var next = 1_000L
    fun nextDelay(): Long = next.also { next = minOf(next * 2, capMs) }
    fun reset() {
        next = 1_000L
    }
}

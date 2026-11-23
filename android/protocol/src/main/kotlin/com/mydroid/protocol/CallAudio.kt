package com.mydroid.protocol

import java.security.GeneralSecurityException
import java.util.TreeMap
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put

/*
 * Mac call audio (PROTOCOL.md section 8), the parts with no Android in them: framing, crypto, the playout queue and the
 * helper's JSON-lines control. The helper itself (com.mydroid.callbridge.Main in :app) and CallBridge wire these to
 * AudioRecord/AudioTrack. Nothing here ever stores audio: frames live in memory for at most a few hundred milliseconds.
 */

/** 20 ms of PCM16 mono at 16 kHz. */
object AudioFmt {
    const val RATE = 16_000
    const val FRAME_MS = 20
    const val FRAME_SAMPLES = RATE * FRAME_MS / 1000 // 320
    const val FRAME_BYTES = FRAME_SAMPLES * 2 // 640
    const val SEQ_BYTES = 4
    const val TAG_BYTES = 16
    const val PACKET_BYTES = SEQ_BYTES + FRAME_BYTES + TAG_BYTES // 660
    const val INFO_DOWN = "mydroid audio down"
    const val INFO_UP = "mydroid audio up"

    /** RMS of little-endian PCM16 in [off, off+len). */
    fun rms(buf: ByteArray, off: Int, len: Int): Double {
        val n = len / 2
        if (n == 0) return 0.0
        var sum = 0.0
        for (i in 0 until n) {
            val s = ((buf[off + 2 * i + 1].toInt() shl 8) or (buf[off + 2 * i].toInt() and 0xff)).toShort().toInt()
            sum += s.toDouble() * s
        }
        return Math.sqrt(sum / n)
    }
}

/** Per-direction keys: `HKDF(key, info="mydroid audio down"|"mydroid audio up")`, empty salt, 32 bytes. */
class AudioKeys(master: ByteArray) {
    init { require(master.size == 32) { "audio key must be 32 bytes" } }
    val down: ByteArray = Hkdf.derive(master, ByteArray(0), AudioFmt.INFO_DOWN, 32)
    val up: ByteArray = Hkdf.derive(master, ByteArray(0), AudioFmt.INFO_UP, 32)
}

private fun audioNonce(seq: Long): ByteArray {
    val n = ByteArray(12) // 4 zero bytes, then u64 big-endian seq
    for (i in 0 until 8) n[11 - i] = (seq ushr (8 * i)).toByte()
    return n
}

/** Builds `u32 seq || AES-256-GCM(key, nonce = 0000 || u64 seq, frame)`. One instance per direction, one thread. */
class AudioSealer(key: ByteArray) {
    private val keySpec = SecretKeySpec(key, "AES")
    private val cipher = Cipher.getInstance("AES/GCM/NoPadding")

    /** [seq] is the full u32 range in a Long. */
    fun seal(seq: Long, frame: ByteArray, off: Int = 0, len: Int = frame.size): ByteArray {
        require(seq in 0..0xFFFF_FFFFL)
        cipher.init(Cipher.ENCRYPT_MODE, keySpec, GCMParameterSpec(128, audioNonce(seq)))
        val out = ByteArray(AudioFmt.SEQ_BYTES + len + AudioFmt.TAG_BYTES)
        out[0] = (seq ushr 24).toByte(); out[1] = (seq ushr 16).toByte(); out[2] = (seq ushr 8).toByte(); out[3] = seq.toByte()
        cipher.doFinal(frame, off, len, out, AudioFmt.SEQ_BYTES)
        return out
    }
}

class AudioPacket(val seq: Long, val frame: ByteArray)

/** Parses and authenticates a packet. Returns null for anything short, forged, or not exactly one frame. One thread. */
class AudioOpener(key: ByteArray) {
    private val keySpec = SecretKeySpec(key, "AES")
    private val cipher = Cipher.getInstance("AES/GCM/NoPadding")

    fun open(data: ByteArray, len: Int = data.size): AudioPacket? {
        if (len != AudioFmt.PACKET_BYTES) return null
        val seq = ((data[0].toLong() and 0xff) shl 24) or ((data[1].toLong() and 0xff) shl 16) or
            ((data[2].toLong() and 0xff) shl 8) or (data[3].toLong() and 0xff)
        return try {
            cipher.init(Cipher.DECRYPT_MODE, keySpec, GCMParameterSpec(128, audioNonce(seq)))
            AudioPacket(seq, cipher.doFinal(data, AudioFmt.SEQ_BYTES, len - AudioFmt.SEQ_BYTES))
        } catch (e: GeneralSecurityException) {
            null
        }
    }
}

/** Accepts each sequence number once and rejects anything more than 64 behind the newest. */
class ReplayWindow {
    private var highest = -1L
    private var mask = 0L // bit i set = (highest - i) seen

    @Synchronized
    fun accept(seq: Long): Boolean {
        if (highest < 0 || seq > highest) {
            val shift = if (highest < 0) 64L else seq - highest
            mask = if (shift >= 64) 1L else (mask shl shift.toInt()) or 1L
            highest = seq
            return true
        }
        val d = highest - seq
        if (d >= 64) return false
        val bit = 1L shl d.toInt()
        if (mask and bit != 0L) return false
        mask = mask or bit
        return true
    }
}

/**
 * The jitter and smoothing buffer in front of the uplink AudioTrack. Frames arrive whenever the network delivers them;
 * [pop] is called once per 20 ms by the write thread and returns the next frame in sequence, or null when the thread
 * should write silence: still pre-buffering, starved, or the frame for that slot never arrived (counted in [lost]).
 */
class PlayoutQueue(private val prefill: Int = 2, private val maxFrames: Int = 8, private val maxGap: Int = 25) {
    private val frames = TreeMap<Long, ByteArray>()
    private var playing = false
    private var lastPlayed = -1L
    var lost = 0L; private set
    var late = 0L; private set
    var dropped = 0L; private set
    var underruns = 0L; private set
    val size: Int @Synchronized get() = frames.size

    @Synchronized
    fun push(seq: Long, frame: ByteArray) {
        if (seq <= lastPlayed) { late++; return }
        if (frames.containsKey(seq)) return
        frames[seq] = frame
        while (frames.size > maxFrames) { frames.pollFirstEntry(); dropped++ } // newest audio wins, latency stays bounded
    }

    @Synchronized
    fun pop(): ByteArray? {
        if (!playing) {
            if (frames.size < prefill) return null
            playing = true
            val first = frames.firstKey()
            if (lastPlayed >= 0 && first - 1 > lastPlayed) lost += first - 1 - lastPlayed
            lastPlayed = first - 1
        }
        if (frames.isEmpty()) { underruns++; playing = false; return null }
        val first = frames.firstKey()
        val expected = lastPlayed + 1
        return when {
            first == expected -> { lastPlayed = expected; frames.pollFirstEntry().value }
            first - expected > maxGap -> { // the sender jumped (paused, restarted): resync instead of playing silence for seconds
                lost += first - expected; lastPlayed = first; frames.pollFirstEntry().value
            }
            else -> { lost++; lastPlayed = expected; null } // that slot never arrived: silence, keep the timeline
        }
    }

    @Synchronized
    fun clear() { frames.clear(); playing = false }
}

enum class CallTier(val wire: String) {
    Full("full"), Listen("listen"), None("none");
    companion object { fun parse(s: String?) = values().firstOrNull { it.wire == s } }
}

/** Mac to helper. */
sealed class HelperCmd {
    class Hello(val macHost: String, val udpPort: Int, val key: ByteArray) : HelperCmd()
    class Route(val toMac: Boolean) : HelperCmd()
    object Quit : HelperCmd()
    class Bad(val reason: String) : HelperCmd()
}

/** The helper's JSON-lines control (PROTOCOL.md 8.3). One JSON object per line, in and out. */
object HelperControl {
    fun parse(line: String): HelperCmd {
        val o = try {
            Json.parseToJsonElement(line.trim()) as? JsonObject ?: return HelperCmd.Bad("not an object")
        } catch (e: Exception) {
            return HelperCmd.Bad("not json")
        }
        fun str(k: String) = (o[k] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
        return when (val cmd = str("cmd")) {
            "hello" -> {
                val host = str("macHost")?.trim().orEmpty()
                val port = (o["udpPort"] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull ?: -1
                val key = try { str("key")?.let { B64.decodeStd(it) } } catch (e: IllegalArgumentException) { null }
                when {
                    host.isEmpty() -> HelperCmd.Bad("hello: macHost")
                    port !in 1..65535 -> HelperCmd.Bad("hello: udpPort")
                    key == null || key.size != 32 -> HelperCmd.Bad("hello: key")
                    else -> HelperCmd.Hello(host, port, key)
                }
            }
            "route" -> when (str("to")) {
                "mac" -> HelperCmd.Route(true)
                "phone" -> HelperCmd.Route(false)
                else -> HelperCmd.Bad("route: to")
            }
            "quit" -> HelperCmd.Quit
            else -> HelperCmd.Bad("unknown cmd ${cmd ?: ""}".trim())
        }
    }

    fun tier(t: CallTier) = buildJsonObject { put("ev", "tier"); put("tier", t.wire) }.toString()
    fun call(inCall: Boolean) = buildJsonObject { put("ev", "call"); put("inCall", inCall) }.toString()

    /** `error` set means the route did not change. `reason` explains an unrequested move back to the phone. */
    fun routed(to: String, error: String? = null, reason: String? = null) = buildJsonObject {
        put("ev", "routed"); put("to", to)
        if (error != null) put("error", error)
        if (reason != null) put("reason", reason)
    }.toString()

    /** Levels and counts only. rxRms: call audio heading to the Mac. txRms: Mac audio going into the call. */
    fun stats(rxRms: Int, txRms: Int, lost: Long, sent: Long, recv: Long, underruns: Long) = buildJsonObject {
        put("ev", "stats"); put("rxRms", rxRms); put("txRms", txRms); put("lost", lost)
        put("sent", sent); put("recv", recv); put("underruns", underruns)
    }.toString()
}

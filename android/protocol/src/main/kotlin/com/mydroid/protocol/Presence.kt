package com.mydroid.protocol

import kotlinx.serialization.json.put

/** The per-pairing BLE service UUIDs, derived from the LTK. */
object Ble {
    /** PROTOCOL.md 7.1: the UUID the Mac advertises (the phone scans for it). */
    fun serviceUuid(ltk: ByteArray): String = derive(ltk, "mydroid v1 ble uuid")

    /** PROTOCOL.md 12: the UUID the phone advertises while walk-away lock is on (the Mac scans for it). */
    fun phoneServiceUuid(ltk: ByteArray): String = derive(ltk, "mydroid v1 phone ble uuid")

    private fun derive(ltk: ByteArray, info: String): String {
        val raw = Hkdf.derive(ltk, ByteArray(0), info, 16)
        raw[6] = ((raw[6].toInt() and 0x0f) or 0x40).toByte()
        raw[8] = ((raw[8].toInt() and 0x3f) or 0x80).toByte()
        val h = Hex.encode(raw)
        return "${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}"
    }
}

/**
 * When the foreground service and every retry should run (PROTOCOL.md 7.1). Pure logic, no clocks or threads:
 * callers pass `now`. With presence disabled (no Bluetooth permission or association) nothing ever parks.
 *
 * Parked = presence enabled, Mac not nearby, no TCP session, and that has been true for [graceMs].
 * Found, a TCP session, or [wake] (Wi-Fi appeared, unlock, app open) un-parks it.
 */
class PresenceMachine(private val graceMs: Long = 120_000) {
    private var enabled = false
    private var present = false
    private var tcp = false
    private var quietSince = 0L

    @Synchronized fun setEnabled(on: Boolean, now: Long) {
        if (on && !enabled) quietSince = now
        if (!on) present = false
        enabled = on
    }
    @Synchronized fun isEnabled() = enabled
    @Synchronized fun onFound() { present = true }
    @Synchronized fun onLost(now: Long) { present = false; if (!tcp) quietSince = now }
    @Synchronized fun onTcp(up: Boolean, now: Long) { tcp = up; if (!up && !present) quietSince = now }
    /** Something that might make the Mac reachable again; restarts the grace window. */
    @Synchronized fun wake(now: Long) { quietSince = now }
    @Synchronized fun isPresent() = present

    @Synchronized fun parked(now: Long): Boolean = enabled && !present && !tcp && now - quietSince >= graceMs

    /** Milliseconds until [parked] becomes true if nothing changes; null if it can't (disabled, present or connected). */
    @Synchronized fun msUntilPark(now: Long): Long? =
        if (!enabled || present || tcp) null else maxOf(0L, quietSince + graceMs - now)
}

/** `link.open` safety (PROTOCOL.md 7.4): http, https and mailto only. */
object Links {
    /** The trimmed URL if it is allowed, else null. */
    fun safe(url: String?): String? {
        val u = url?.trim() ?: return null
        if (u.isEmpty() || u.length > 8192 || u.any { it.isWhitespace() || it.isISOControl() }) return null
        val colon = u.indexOf(':')
        if (colon <= 0) return null
        val scheme = u.substring(0, colon).lowercase()
        val rest = u.substring(colon + 1)
        return when (scheme) {
            "http", "https" -> if (rest.startsWith("//") && rest.length > 2 && rest[2] != '/') u else null
            "mailto" -> if (rest.isNotEmpty()) u else null
            else -> null
        }
    }
}

/** Remembers which package each mirrored notification belongs to, so a newly muted app's can be withdrawn (7.2). */
class MuteTracker {
    @Volatile private var muted: Set<String> = emptySet()
    private val sent = java.util.concurrent.ConcurrentHashMap<String, String>()

    fun isMuted(pkg: String) = pkg in muted
    fun sent(key: String, pkg: String) { sent[key] = pkg }
    fun forget(key: String) { sent.remove(key) }
    fun clear() = sent.clear()

    /** Applies a new mute list; returns the keys already mirrored that must now get `notif.removed`. */
    fun update(newMuted: Set<String>): List<String> {
        muted = newMuted
        val out = sent.filterValues { it in newMuted }.keys.toList()
        out.forEach { sent.remove(it) }
        return out
    }
}

/** What the phone knows about the best media session at one moment. */
data class MediaSnapshot(
    val pkg: String, val title: String, val artist: String, val album: String,
    val playing: Boolean, val position: Long, val duration: Long, val ts: Long,
    val canSeek: Boolean, val canNext: Boolean, val canPrev: Boolean, val hasArt: Boolean,
    /** `spotify:track:…`, `spotify:episode:…` or an http(s) URL, already filtered by [MediaIds] (PROTOCOL.md 15); null when the player gives none. */
    val mediaId: String? = null,
) {
    /** A new key means a new track: art is resent and the Mac is told. The id is part of it, so the same title with another id counts. */
    val trackKey get() = "$pkg\u0000$title\u0000$artist\u0000$album\u0000${mediaId.orEmpty()}"

    /** The `media.state` for this snapshot. [art] is base64 JPEG, only when the track changed. [mediaId] is only ever sent when it passes [MediaIds.filter]. */
    fun toMessage(app: String, art: String?): Message = Message.of("media.state") {
        put("active", true); put("pkg", pkg); put("app", app)
        put("title", title); put("artist", artist); put("album", album)
        if (art != null) put("art", art)
        MediaIds.filter(mediaId)?.let { put("mediaId", it) }
        put("playing", playing); put("position", position); put("duration", duration); put("ts", ts)
        put("canSeek", canSeek); put("canNext", canNext); put("canPrev", canPrev)
    }
}

/** `media.cmd` (PROTOCOL.md 7.3) turned into what the phone does to the active session. */
enum class MediaAction {
    Play, Pause, Next, Prev, Seek;

    companion object {
        /** Null for an action the phone doesn't know. `toggle` depends on whether something is [playing] now. */
        fun parse(action: String?, playing: Boolean): MediaAction? = when (action) {
            "play" -> Play
            "pause" -> Pause
            "toggle" -> if (playing) Pause else Play
            "next" -> Next
            "prev" -> Prev
            "seek" -> Seek
            else -> null
        }
    }
}

/**
 * Decides when `media.state` is worth sending (PROTOCOL.md 7.3): on change only, never on a timer.
 * A position-only change is sent only if it looks like a seek (the position left the extrapolated line).
 */
class MediaTracker(private val seekSlackMs: Long = 2_000) {
    class Decision(val send: Boolean, val withArt: Boolean)
    private var last: MediaSnapshot? = null
    private var active = false
    private var artSentFor: String? = null

    fun reset() { last = null; active = false; artSentFor = null }

    /** [s] == null means no session. */
    fun decide(s: MediaSnapshot?): Decision {
        if (s == null) {
            val was = active
            last = null; active = false; artSentFor = null
            return Decision(was, false)
        }
        val l = last
        last = s
        val wasActive = active
        active = true
        val artNow = s.hasArt && artSentFor != s.trackKey
        if (!wasActive || l == null) return mark(s, artNow, true)
        val changed = l.trackKey != s.trackKey || l.duration != s.duration || l.playing != s.playing ||
            l.canSeek != s.canSeek || l.canNext != s.canNext || l.canPrev != s.canPrev
        if (changed || artNow) return mark(s, artNow, true)
        val expected = l.position + if (l.playing) (s.ts - l.ts) else 0L
        val seeked = kotlin.math.abs(s.position - expected) > seekSlackMs
        if (!seeked) last = l // keep the older sample: drift must be measured against what the Mac extrapolates from
        return Decision(seeked, false)
    }

    private fun mark(s: MediaSnapshot, art: Boolean, send: Boolean): Decision {
        if (art) artSentFor = s.trackKey
        return Decision(send, art)
    }
}

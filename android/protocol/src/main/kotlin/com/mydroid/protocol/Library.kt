package com.mydroid.protocol

import kotlinx.serialization.json.*

/**
 * Pure (JVM) parts of PROTOCOL.md 7.5 to 7.8: wire encoding, paging, frame budgeting, send tracking and
 * change detection. Everything that touches Android (ContentProviders, SmsManager, MediaStore) lives in `:app`
 * and calls into here, so the logic that can be wrong is unit-tested.
 */

/** A number or a numeric string, so a peer that sends ids as strings still works. */
fun Message.flexLong(k: String): Long? {
    val p = header[k] as? JsonPrimitive ?: return null
    return p.longOrNull ?: p.contentOrNull?.trim()?.toLongOrNull()
}

fun Message.flexLongs(k: String): List<Long> =
    arr(k)?.mapNotNull { e -> (e as? JsonPrimitive)?.let { it.longOrNull ?: it.contentOrNull?.trim()?.toLongOrNull() } } ?: emptyList()

// ------------------------------------------------------------------------------------------------ paging

class Page<T>(val items: List<T>, val more: Boolean)

object Paging {
    /** How many rows beyond the page size each query fetches, so a run of equal timestamps at the edge isn't split. */
    const val TIE_EXTRA = 100

    /** Both inputs newest first. Stable: on equal dates, [a] comes before [b]. */
    fun <T> merge(a: List<T>, b: List<T>, date: (T) -> Long): List<T> {
        val out = ArrayList<T>(a.size + b.size)
        var i = 0
        var j = 0
        while (i < a.size || j < b.size) {
            out += if (j >= b.size || (i < a.size && date(a[i]) >= date(b[j]))) a[i++] else b[j++]
        }
        return out
    }

    /**
     * Takes the newest [limit] items of [sortedDesc]. The page is extended to include every following item with the
     * same date as its last one, because the next request asks for `date < before` and would otherwise skip them.
     * [moreBeyondInput] says the source itself was cut off (it returned its row cap), so there may be more rows.
     */
    fun <T> page(sortedDesc: List<T>, limit: Int, date: (T) -> Long, moreBeyondInput: Boolean = false): Page<T> {
        val n = limit.coerceAtLeast(1)
        if (sortedDesc.size <= n) return Page(sortedDesc, moreBeyondInput)
        val edge = date(sortedDesc[n - 1])
        var end = n
        while (end < sortedDesc.size && date(sortedDesc[end]) == edge) end++
        return Page(sortedDesc.subList(0, end), end < sortedDesc.size || moreBeyondInput)
    }

    /** `limit` from a request: default when missing, clamped to 1..[max]. */
    fun limit(requested: Int?, default: Int, max: Int): Int = (requested ?: default).coerceIn(1, max)
}

// ------------------------------------------------------------------------------------------------ frame budget

object FrameBudget {
    /** Encrypted frame = 12-byte nonce + ciphertext + 16-byte tag, and the whole frame must stay under 1 MiB. */
    const val OVERHEAD = 12 + 16
    const val MAX_BODY = MAX_FRAME - OVERHEAD - 4096

    fun fits(m: Message): Boolean = Codec.encode(m).size <= MAX_BODY

    fun jsonBytes(o: JsonObject): Int = o.toString().toByteArray(Charsets.UTF_8).size + 1

    /**
     * Largest prefix of [items] whose summed [sizeOf] stays within [budget] (always at least one item, even if that one
     * is too big on its own, so progress is possible).
     */
    fun <T> prefix(items: List<T>, budget: Int, sizeOf: (T) -> Int): Int {
        var total = 0
        for ((i, it) in items.withIndex()) {
            total += sizeOf(it)
            if (total > budget && i > 0) return i
        }
        return items.size
    }
}

// ------------------------------------------------------------------------------------------------ SMS (7.5)

data class SmsThread(
    val threadId: Long,
    val addresses: List<String>,
    val name: String,
    val snippet: String,
    val date: Long,
    val unread: Int,
    /** base64 PNG, at most 128 px. */
    val avatar: String? = null,
)

/**
 * `id` is the SMS `_id`, or the negated MMS `_id` (the two tables number their rows independently, so a plain `_id`
 * would collide). `from` is the sender's address for received messages and "" for ones the user sent.
 */
data class SmsMsg(
    val id: Long,
    val from: String,
    val body: String,
    val date: Long,
    val out: Boolean,
    val status: String,
    val mms: Boolean = false,
)

object SmsWire {
    const val MAX_SNIPPET = 200
    const val MAX_BODY = 8_000
    const val DEFAULT_LIMIT = 50
    const val MAX_LIMIT = 200

    fun limit(requested: Int?) = Paging.limit(requested, DEFAULT_LIMIT, MAX_LIMIT)

    /** Cut to [max] UTF-16 units without ending on half a surrogate pair. */
    fun clip(s: String, max: Int): String {
        if (s.length <= max) return s
        val end = if (Character.isHighSurrogate(s[max - 1])) max - 1 else max
        return s.substring(0, end)
    }

    fun threadJson(t: SmsThread, withAvatar: Boolean = true): JsonObject = buildJsonObject {
        put("threadId", t.threadId)
        put("addresses", JsonArray(t.addresses.map { JsonPrimitive(it) }))
        put("name", t.name)
        put("snippet", clip(t.snippet, MAX_SNIPPET))
        put("date", t.date)
        put("unread", t.unread)
        if (withAvatar && t.avatar != null) put("avatar", t.avatar)
    }

    fun messageJson(m: SmsMsg): JsonObject = buildJsonObject {
        put("id", m.id)
        put("from", m.from)
        put("body", clip(m.body, MAX_BODY))
        put("date", m.date)
        put("out", m.out)
        put("status", m.status)
        if (m.mms) put("mms", true)
    }

    /**
     * `sms.threads`, newest first. Contact photos are the bulk of the bytes: when the frame would be too big the
     * oldest threads lose their avatar first, then trailing threads are dropped (the Mac pages with `before`).
     */
    fun threads(threads: List<SmsThread>): Message {
        val avatars = threads.map { it.avatar != null }.toMutableList()
        fun size(i: Int) = threadJson(threads[i], avatars[i]).let { FrameBudget.jsonBytes(it) }
        var sizes = threads.indices.map(::size).toMutableList()
        var total = sizes.sum()
        val budget = FrameBudget.MAX_BODY - 512
        var i = threads.size - 1
        while (total > budget && i >= 0) {
            if (avatars[i]) { avatars[i] = false; val s = size(i); total -= sizes[i] - s; sizes[i] = s }
            i--
        }
        val keep = FrameBudget.prefix(threads.indices.toList(), budget) { sizes[it] }
        return Message.of("sms.threads") {
            put("threads", JsonArray((0 until keep).map { threadJson(threads[it], avatars[it]) }))
        }
    }

    /** `sms.messages`, [messages] oldest first. If too big the oldest are dropped (the Mac pages with `before`). */
    fun messages(threadId: Long, messages: List<SmsMsg>): Message {
        val objs = messages.map(::messageJson)
        val budget = FrameBudget.MAX_BODY - 512
        // Keep the newest messages that fit: measure from the end.
        val keepFromEnd = FrameBudget.prefix(objs.asReversed(), budget) { FrameBudget.jsonBytes(it) }
        return Message.of("sms.messages") {
            put("threadId", threadId)
            put("messages", JsonArray(objs.subList(objs.size - keepFromEnd, objs.size)))
        }
    }

    fun changed(threadId: Long): Message = Message.of("sms.changed") { put("threadId", threadId) }

    fun sent(clientId: String, ok: Boolean, error: String?, threadId: Long?): Message = Message.of("sms.sent") {
        put("clientId", clientId); put("ok", ok)
        if (error != null) put("error", error)
        if (threadId != null) put("threadId", threadId)
    }

    /** `sms.error`. `error` is "permission" when READ_SMS/SEND_SMS or `settings.smsHistory` is missing, else "failed". */
    fun error(kind: String, request: String? = null): Message = Message.of("sms.error") {
        put("error", kind)
        if (request != null) put("req", request)
    }

    /** android.provider.Telephony.Sms.TYPE_*: 1 inbox, 2 sent, 3 draft, 4 outbox, 5 failed, 6 queued. */
    fun statusOfSmsType(type: Int): String = when (type) {
        1 -> "received"
        2 -> "sent"
        5 -> "failed"
        3, 4, 6 -> "pending"
        else -> "received"
    }

    /** Telephony.Mms.MESSAGE_BOX_*: 1 inbox, 2 sent, 3 drafts, 4 outbox. */
    fun statusOfMmsBox(box: Int): String = when (box) {
        1 -> "received"
        2 -> "sent"
        3, 4 -> "pending"
        else -> "received"
    }

    fun isOutSmsType(type: Int) = type != 1
    fun isOutMmsBox(box: Int) = box != 1

    /** MMS text: its text part when it has one, else a placeholder for what it carries. */
    fun mmsBody(texts: List<String>, mimeTypes: List<String>): String {
        val text = texts.map { it.trim() }.filter { it.isNotEmpty() }.joinToString("\n")
        if (text.isNotEmpty()) return text
        return when {
            mimeTypes.any { it.startsWith("image/") } -> "[Photo]"
            mimeTypes.any { it.startsWith("video/") } -> "[Video]"
            mimeTypes.any { it.startsWith("audio/") } -> "[Audio]"
            else -> "[Attachment]"
        }
    }

    /** Thread snippet: the stored one, or a placeholder when an attachment-only message left it empty. */
    fun snippet(stored: String?, hasAttachment: Boolean): String =
        stored?.trim()?.takeIf { it.isNotEmpty() } ?: if (hasAttachment) "[Photo]" else ""
}

/** The numbers phone apps compare on: digits only, last 10; alphanumeric senders compare as lowercase text. */
object PhoneKey {
    fun of(number: String): String {
        val n = number.trim()
        if (n.any { it.isLetter() }) return n.lowercase()
        val d = n.filter { it.isDigit() }
        return if (d.length > 10) d.takeLast(10) else d
    }
}

/** Display name for a thread: contact names (or numbers) joined, "+N" past three. */
object ThreadNames {
    fun title(labels: List<String>): String = when {
        labels.isEmpty() -> ""
        labels.size <= 3 -> labels.joinToString(", ")
        else -> labels.take(3).joinToString(", ") + " +${labels.size - 3}"
    }
}

/** Android's `SmsManager.RESULT_ERROR_*` codes, as sentIntent result codes, in words a person can act on. */
object SmsErrors {
    fun describe(code: Int): String = when (code) {
        2 -> "Your phone is in airplane mode or has no signal"
        3 -> "That text couldn't be encoded"
        4 -> "Your phone has no mobile service"
        5 -> "Your phone is sending too many texts. Try again in a moment"
        6, 7 -> "That number can't be texted"
        8 -> "Your phone isn't allowed to send texts"
        else -> "Your phone couldn't send that text"
    }
}

/** Collects the per-part `sentIntent` results of one `sms.send` and reports once, when the last part is in. */
class SendTracker {
    class Outcome(val clientId: String, val ok: Boolean, val error: String?, val threadId: Long?)

    private class Pending(var left: Int, val threadId: Long?, var error: String? = null)

    private val pending = HashMap<String, Pending>()

    /** [parts] = recipients x message parts. */
    @Synchronized
    fun begin(clientId: String, parts: Int, threadId: Long?) {
        pending[clientId] = Pending(parts.coerceAtLeast(1), threadId)
    }

    @Synchronized
    fun partResult(clientId: String, ok: Boolean, error: String?): Outcome? {
        val p = pending[clientId] ?: return null
        if (!ok && p.error == null) p.error = error ?: "Your phone couldn't send that text"
        p.left--
        if (p.left > 0) return null
        pending.remove(clientId)
        return Outcome(clientId, p.error == null, p.error, p.threadId)
    }

    /** Gave up waiting. Null if it already completed. */
    @Synchronized
    fun expire(clientId: String): Outcome? {
        val p = pending.remove(clientId) ?: return null
        return Outcome(clientId, false, p.error ?: "Your phone didn't confirm that the text was sent", p.threadId)
    }

    @Synchronized
    fun isPending(clientId: String) = clientId in pending
}

/**
 * Decides which threads to announce with `sms.changed`: compares successive snapshots of the thread table and
 * sends at most one announcement per thread per [minIntervalMs]. A thread that changed too soon after its last
 * announcement is held back (and reported through [Result.retryInMs]) rather than lost.
 */
class ThreadChangeTracker(private val minIntervalMs: Long = 1_000) {
    data class Sig(val date: Long, val count: Int, val read: Int)
    class Result(val changed: List<Long>, val retryInMs: Long?)

    private var baseline: MutableMap<Long, Sig>? = null
    private val lastSent = HashMap<Long, Long>()

    /** Forget everything; the next [diff] only records a baseline. */
    @Synchronized
    fun reset() { baseline = null; lastSent.clear() }

    @Synchronized
    fun diff(now: Map<Long, Sig>, nowMs: Long): Result {
        val base = baseline
        if (base == null) {
            baseline = now.toMutableMap()
            return Result(emptyList(), null)
        }
        val out = ArrayList<Long>()
        var retry: Long? = null
        for ((id, sig) in now) {
            if (base[id] == sig) continue
            val wait = (lastSent[id] ?: Long.MIN_VALUE).let { if (it == Long.MIN_VALUE) 0L else minIntervalMs - (nowMs - it) }
            if (wait > 0) { retry = minOf(retry ?: wait, wait); continue }
            out += id
            base[id] = sig
            lastSent[id] = nowMs
        }
        for (id in base.keys.toList()) {
            if (id !in now) { base.remove(id); lastSent.remove(id); out += id }
        }
        return Result(out, retry)
    }
}

// ------------------------------------------------------------------------------------------------ photos (7.7)

data class PhotoItem(
    val id: Long,
    val name: String,
    val taken: Long,
    val w: Int,
    val h: Int,
    val size: Long,
    val mime: String,
    val album: String,
)

object PhotoWire {
    const val DEFAULT_LIMIT = 60
    const val MAX_LIMIT = 200
    const val MAX_THUMBS = 30
    const val THUMB_PX = 256
    const val THUMB_QUALITY = 80

    fun limit(requested: Int?) = Paging.limit(requested, DEFAULT_LIMIT, MAX_LIMIT)

    /** `"camera"`, `"screenshots"` or `"all"`; anything else (or nothing) means all. */
    fun album(requested: String?): String = when (requested?.lowercase()) {
        "camera" -> "camera"
        "screenshots" -> "screenshots"
        else -> "all"
    }

    /** The album a photo belongs to, from its MediaStore RELATIVE_PATH and name. */
    fun albumOf(relativePath: String?, displayName: String?): String {
        val rp = relativePath.orEmpty()
        return when {
            rp.contains("Screenshot", ignoreCase = true) || displayName.orEmpty().startsWith("Screenshot", ignoreCase = true) -> "screenshots"
            rp.startsWith("DCIM/Camera", ignoreCase = true) -> "camera"
            else -> "other"
        }
    }

    /** DATE_TAKEN (ms) when set, else DATE_ADDED (seconds) as ms. */
    fun effectiveDate(dateTaken: Long?, dateAddedSec: Long): Long =
        if (dateTaken != null && dateTaken > 0) dateTaken else dateAddedSec * 1000

    /** Width and height as displayed: EXIF orientation 90 or 270 swaps them. */
    fun displaySize(w: Int, h: Int, orientation: Int): Pair<Int, Int> = if (orientation == 90 || orientation == 270) h to w else w to h

    /** Scale so the long edge is at most [maxPx]; never upscales. */
    fun fitSize(w: Int, h: Int, maxPx: Int = THUMB_PX): Pair<Int, Int> {
        val longest = maxOf(w, h)
        if (longest <= maxPx || longest <= 0) return w to h
        val s = maxPx.toDouble() / longest
        return maxOf(1, Math.round(w * s).toInt()) to maxOf(1, Math.round(h * s).toInt())
    }

    fun itemJson(p: PhotoItem): JsonObject = buildJsonObject {
        put("id", p.id); put("name", p.name); put("taken", p.taken)
        put("w", p.w); put("h", p.h); put("size", p.size); put("mime", p.mime); put("album", p.album)
    }

    fun page(page: Page<PhotoItem>, error: String? = null): Message = Message.of("photos.page") {
        put("items", JsonArray(page.items.map(::itemJson)))
        put("more", page.more)
        if (error != null) put("error", error)
    }

    fun thumb(id: Long, jpeg: ByteArray?): Message =
        if (jpeg != null) Message.of("photos.thumb", jpeg) { put("id", id) } else Message.of("photos.thumb") { put("id", id); put("ok", false) }

    fun libraryXid(id: Long) = "lib:$id"
}

// ------------------------------------------------------------------------------------------------ calls (7.8)

data class CallItem(val number: String, val name: String, val kind: String, val date: Long, val duration: Long)

object CallWire {
    const val DEFAULT_LIMIT = 100
    const val MAX_LIMIT = 500

    fun limit(requested: Int?) = Paging.limit(requested, DEFAULT_LIMIT, MAX_LIMIT)

    /** CallLog.Calls.TYPE: 1 incoming, 2 outgoing, 3 missed, 4 voicemail, 5 rejected, 6 blocked, 7 answered elsewhere. */
    fun kindOf(type: Int): String = when (type) {
        2 -> "out"
        3 -> "missed"
        5, 6 -> "rejected"
        else -> "in"
    }

    fun itemJson(c: CallItem): JsonObject = buildJsonObject {
        put("number", c.number); put("name", c.name); put("kind", c.kind); put("date", c.date); put("duration", c.duration)
    }

    fun page(items: List<CallItem>, error: String? = null): Message {
        val objs = items.map(::itemJson)
        val keep = FrameBudget.prefix(objs, FrameBudget.MAX_BODY - 512) { FrameBudget.jsonBytes(it) }
        return Message.of("calls.page") {
            put("items", JsonArray(objs.take(keep)))
            if (error != null) put("error", error)
        }
    }

    /**
     * A dialable number: digits with an optional leading `+`, tolerating spaces, dots, dashes and parentheses.
     * No `*` or `#`: those can start USSD codes and call-forwarding changes. Returns the cleaned number or null.
     */
    fun dialable(raw: String?): String? {
        val s = raw?.trim() ?: return null
        if (s.isEmpty() || s.length > 32) return null
        if (!s.all { it.isDigit() || it in "+ ().-" }) return null
        if (s.indexOf('+') > 0 || s.count { it == '+' } > 1) return null
        val cleaned = s.filter { it.isDigit() || it == '+' }
        val digits = cleaned.count { it.isDigit() }
        return if (digits in 3..20) cleaned else null
    }
}

// ------------------------------------------------------------------------------------------------ read sync (7.6)

object MarkRead {
    /** Titles apps use for the "mark as read" action, lowercase. English first; the rest are common UI languages. */
    private val titles = setOf(
        "mark as read", "mark read", "mark all as read",
        "marcar como leído", "marcar como leida", "marcar como lido", "marcar como lida", "marcar leído",
        "marquer comme lu", "als gelesen markieren", "gelesen", "segna come letto", "segna come letta",
        "als gelezen markeren", "oznacz jako przeczytane", "отметить как прочитанное", "прочитано",
        "okundu olarak işaretle", "tandai sudah dibaca", "tandai dibaca", "đánh dấu là đã đọc",
        "標示為已讀", "标记为已读", "标为已读", "既読にする", "읽음으로 표시",
        "मार्क ऐज़ रीड", "पढ़ा हुआ चिह्नित करें", "पढ़ा हुआ मार्क करें",
        "markera som läst", "marker som lest", "mark. som læst", "merk som lest", "merkitse luetuksi",
    )

    fun titleMatches(title: CharSequence?): Boolean {
        val t = title?.toString()?.trim()?.trimEnd('.', '!', '…')?.lowercase() ?: return false
        return t in titles
    }

    /** Notification.Action.SEMANTIC_ACTION_MARK_AS_READ */
    const val SEMANTIC_MARK_AS_READ = 2

    fun isMarkRead(semanticAction: Int, title: CharSequence?): Boolean = semanticAction == SEMANTIC_MARK_AS_READ || titleMatches(title)
}

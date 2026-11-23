package com.mydroid.android.transfers

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

enum class Direction { ToMac, FromMac }
enum class Kind { File, Text, Link, Auth }

/** One finished (or failed) transfer in the Activity list. Text and link entries never keep the text itself. */
data class ActivityEntry(
    val id: String,
    val dir: Direction,
    val kind: Kind,
    val title: String,
    val detail: String?,
    val at: Long,
    val ok: Boolean = true,
)

/** A send that is waiting for the Mac to be reachable. Files are durable; a pending text lives in memory only. */
data class QueuedItem(val id: String, val kind: Kind, val name: String, val size: Long = 0)

/** A send in flight. [total] is 0 until the size is known. */
data class LiveTransfer(val id: String, val name: String, val sent: Long, val total: Long) {
    val fraction: Float get() = if (total <= 0) 0f else (sent.toFloat() / total).coerceIn(0f, 1f)
}

data class TransfersState(
    val live: List<LiveTransfer> = emptyList(),
    val queued: List<QueuedItem> = emptyList(),
    /** Newest first. */
    val recent: List<ActivityEntry> = emptyList(),
    /** Times (epoch ms) of recently synced camera photos, newest last. Used for "12 photos synced today". */
    val photoTimes: List<Long> = emptyList(),
) {
    fun photosSince(startOfDay: Long): Int = photoTimes.count { it >= startOfDay }
}

/** A file waiting in the durable outbox. [uri] is usually a file:// copy in [Transfers.outboxDir]: share and picker grants end with the screen that gave them. */
data class OutboxFile(val id: String, val uri: String, val name: String, val mime: String, val size: Long, val addedAt: Long)

/**
 * Small, durable bookkeeping for the everyday screen: the last [MAX_ENTRIES] transfers (JSON in app storage),
 * the files waiting for the Mac, and live progress. No file or clipboard content is ever written here, only names and sizes
 * the user already sees on screen.
 */
class Transfers(context: Context?, private val dir: File? = context?.filesDir) {
    private val activityFile = dir?.let { File(it, "activity.json") }
    private val outboxFile = dir?.let { File(it, "outbox_files.json") }
    private val entries = ArrayList<ActivityEntry>()
    private val photoTimes = ArrayList<Long>()
    private val outbox = ArrayList<OutboxFile>()
    /** Private copies of queued files, deleted once each is sent, dropped or expired. */
    val outboxDir: File? = dir?.let { File(it, "outbox") }
    private val live = LinkedHashMap<String, LiveTransfer>()
    private var pendingText: QueuedItem? = null
    private val _state = MutableStateFlow(TransfersState())
    val state: StateFlow<TransfersState> get() = _state

    init {
        runCatching {
            if (activityFile?.exists() == true) {
                val o = JSONObject(activityFile.readText())
                o.optJSONArray("entries")?.let { a ->
                    for (i in 0 until a.length()) {
                        val j = a.getJSONObject(i)
                        entries += ActivityEntry(
                            j.getString("id"), Direction.valueOf(j.getString("dir")), Kind.valueOf(j.getString("kind")),
                            j.getString("title"), j.optString("detail").ifEmpty { null }, j.getLong("at"), j.optBoolean("ok", true),
                        )
                    }
                }
                o.optJSONArray("photos")?.let { a -> for (i in 0 until a.length()) photoTimes += a.getLong(i) }
            }
        }
        runCatching {
            if (outboxFile?.exists() == true) {
                val a = JSONArray(outboxFile.readText())
                for (i in 0 until a.length()) {
                    val j = a.getJSONObject(i)
                    outbox += OutboxFile(j.getString("id"), j.getString("uri"), j.getString("name"), j.getString("mime"), j.getLong("size"), j.getLong("addedAt"))
                }
            }
        }
        publish()
    }

    // ------------------------------------------------------------------ history

    @Synchronized
    fun record(e: ActivityEntry) {
        entries.add(0, e)
        while (entries.size > MAX_ENTRIES) entries.removeAt(entries.size - 1)
        persistActivity(); publish()
    }

    fun recordFile(dir: Direction, name: String, size: Long, ok: Boolean = true, error: String? = null) {
        val detail = if (ok) formatSize(size) else error ?: "Couldn't send"
        record(ActivityEntry(UUID.randomUUID().toString(), dir, Kind.File, name, detail, System.currentTimeMillis(), ok))
    }

    @Synchronized
    fun photoSynced() {
        photoTimes += System.currentTimeMillis()
        while (photoTimes.size > MAX_PHOTO_TIMES) photoTimes.removeAt(0)
        persistActivity(); publish()
    }

    @Synchronized
    fun clearAll() {
        outbox.forEach(::release)
        entries.clear(); photoTimes.clear(); outbox.clear(); live.clear(); pendingText = null
        persistActivity(); persistOutbox(); publish()
    }

    // ------------------------------------------------------------------ outbox (files)

    @Synchronized
    fun enqueue(f: OutboxFile) {
        outbox += f; persistOutbox(); publish()
    }

    @Synchronized fun nextQueued(now: Long = System.currentTimeMillis()): OutboxFile? {
        val stale = outbox.filter { now - it.addedAt > OUTBOX_TTL_MS }.onEach(::release).isNotEmpty()
        if (stale) outbox.removeAll { now - it.addedAt > OUTBOX_TTL_MS }
        if (stale) { persistOutbox(); publish() }
        return outbox.firstOrNull()
    }

    @Synchronized fun hasQueued() = outbox.isNotEmpty()

    @Synchronized
    fun dequeue(id: String) {
        val gone = outbox.filter { it.id == id }
        if (gone.isEmpty()) return
        gone.forEach(::release)
        outbox.removeAll { it.id == id }; persistOutbox(); publish()
    }

    /** Copies that no queued entry points at any more (a crash between copy and enqueue). */
    @Synchronized
    fun pruneOutboxDir() {
        val keep = outbox.mapNotNull { copyOf(it)?.name }.toSet()
        outboxDir?.listFiles()?.forEach { if (it.name !in keep) it.delete() }
    }

    private fun copyOf(f: OutboxFile): File? {
        val d = outboxDir ?: return null
        if (!f.uri.startsWith("file:")) return null
        val file = runCatching { File(java.net.URI(f.uri)) }.getOrNull() ?: return null
        return file.takeIf { it.parentFile?.canonicalPath == d.canonicalPath }
    }

    private fun release(f: OutboxFile) { copyOf(f)?.delete() }

    @Synchronized
    fun setPendingText(kind: Kind, label: String) {
        pendingText = QueuedItem("text", kind, label); publish()
    }

    @Synchronized
    fun clearPendingText() {
        if (pendingText != null) { pendingText = null; publish() }
    }

    // ------------------------------------------------------------------ live

    @Synchronized
    fun liveStart(id: String, name: String, total: Long) {
        live[id] = LiveTransfer(id, name, 0, total); publish()
    }

    @Synchronized
    fun liveProgress(id: String, sent: Long) {
        val t = live[id] ?: return
        live[id] = t.copy(sent = sent); publish()
    }

    @Synchronized
    fun liveEnd(id: String) {
        if (live.remove(id) != null) publish()
    }

    // ------------------------------------------------------------------ plumbing

    private fun publish() {
        val liveIds = live.keys
        val queued = buildList {
            outbox.filter { it.id !in liveIds }.forEach { add(QueuedItem(it.id, Kind.File, it.name, it.size)) }
            pendingText?.let { add(it) }
        }
        _state.value = TransfersState(live.values.toList(), queued, entries.toList(), photoTimes.toList())
    }

    private fun persistActivity() {
        val f = activityFile ?: return
        runCatching {
            val o = JSONObject()
            o.put("entries", JSONArray().also { a ->
                entries.forEach { e ->
                    a.put(JSONObject().put("id", e.id).put("dir", e.dir.name).put("kind", e.kind.name).put("title", e.title)
                        .put("detail", e.detail ?: "").put("at", e.at).put("ok", e.ok))
                }
            })
            o.put("photos", JSONArray(photoTimes.toList()))
            writeAtomic(f, o.toString())
        }
    }

    private fun persistOutbox() {
        val f = outboxFile ?: return
        runCatching {
            writeAtomic(f, JSONArray().also { a ->
                outbox.forEach { o ->
                    a.put(JSONObject().put("id", o.id).put("uri", o.uri).put("name", o.name).put("mime", o.mime).put("size", o.size).put("addedAt", o.addedAt))
                }
            }.toString())
        }
    }

    private fun writeAtomic(f: File, text: String) {
        val tmp = File(f.path + ".tmp")
        tmp.writeText(text)
        tmp.renameTo(f)
    }

    companion object {
        const val MAX_ENTRIES = 50
        private const val MAX_PHOTO_TIMES = 300
        const val OUTBOX_TTL_MS = 24 * 60 * 60_000L

        fun formatSize(bytes: Long): String = when {
            bytes < 1000 -> "$bytes B"
            bytes < 1_000_000 -> "${bytes / 1000} KB"
            bytes < 1_000_000_000 -> String.format(java.util.Locale.US, "%.1f MB", bytes / 1e6)
            else -> String.format(java.util.Locale.US, "%.1f GB", bytes / 1e9)
        }
    }
}

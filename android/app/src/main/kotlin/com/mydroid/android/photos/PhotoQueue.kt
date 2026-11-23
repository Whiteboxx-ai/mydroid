package com.mydroid.android.photos

import android.content.ContentUris
import android.content.Context
import android.net.Uri
import android.provider.MediaStore
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

data class QueuedPhoto(val id: Long, val modified: Long, val name: String, val mime: String, val taken: Long, val size: Long) {
    val xid: String get() = "photo:$id:$modified"
    val uri: Uri get() = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)
}

/**
 * Durable queue of photos not yet marked done (`xfer.done ok` or `xfer.skip`).
 * Persisted as JSON in filesDir; also remembers recently seen xids so rescans don't re-queue.
 */
class PhotoQueue(context: Context) {
    private val file = File(context.filesDir, "photo_queue.json")
    private val items = ArrayList<QueuedPhoto>()
    private val seen = LinkedHashSet<String>()
    private val _count = MutableStateFlow(0)
    val count: StateFlow<Int> get() = _count

    init {
        runCatching {
            if (file.exists()) {
                val o = JSONObject(file.readText())
                o.optJSONArray("items")?.let { a ->
                    for (i in 0 until a.length()) {
                        val j = a.getJSONObject(i)
                        items += QueuedPhoto(j.getLong("id"), j.getLong("modified"), j.getString("name"), j.getString("mime"), j.getLong("taken"), j.getLong("size"))
                    }
                }
                o.optJSONArray("seen")?.let { a -> for (i in 0 until a.length()) seen += a.getString(i) }
            }
        }
        _count.value = items.size
    }

    @Synchronized
    private fun persist() {
        val o = JSONObject()
        o.put("items", JSONArray().also { a ->
            items.forEach { p ->
                a.put(JSONObject().put("id", p.id).put("modified", p.modified).put("name", p.name).put("mime", p.mime).put("taken", p.taken).put("size", p.size))
            }
        })
        while (seen.size > 600) seen.remove(seen.first())
        o.put("seen", JSONArray(seen.toList()))
        val tmp = File(file.path + ".tmp")
        tmp.writeText(o.toString())
        tmp.renameTo(file)
        _count.value = items.size
    }

    /** Adds photos not seen before; returns how many were new. */
    @Synchronized
    fun addNew(found: List<QueuedPhoto>): Int {
        var n = 0
        for (p in found) {
            if (p.xid in seen) continue
            seen += p.xid; items += p; n++
        }
        if (n > 0) persist()
        return n
    }

    @Synchronized fun peek(): QueuedPhoto? = items.firstOrNull()
    @Synchronized fun snapshot(): List<QueuedPhoto> = items.toList()
    @Synchronized fun isEmpty() = items.isEmpty()

    @Synchronized
    fun remove(xid: String) {
        if (items.removeAll { it.xid == xid }) persist()
    }

    /** A transfer failed: let others go first. */
    @Synchronized
    fun moveToBack(xid: String) {
        val i = items.indexOfFirst { it.xid == xid }
        if (i >= 0 && items.size > 1) {
            items.add(items.removeAt(i)); persist()
        }
    }

    @Synchronized
    fun clear() {
        items.clear(); seen.clear(); persist()
    }
}

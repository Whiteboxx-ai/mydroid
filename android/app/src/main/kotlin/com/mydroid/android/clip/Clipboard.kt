package com.mydroid.android.clip

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import com.mydroid.protocol.Message
import kotlinx.serialization.json.put

object Clipboard {
    const val MAX_BYTES = 1 shl 20

    /** Last text that went over the wire in either direction. Stops echoes and repeat sends. */
    @Volatile private var lastSynced: String? = null

    fun markSynced(text: String) { lastSynced = text }
    fun alreadySynced(text: String) = text == lastSynced

    /** Password managers flag clips; both the SDK constant (API 33+) and the literal key are checked. Never send those. */
    fun isSensitive(d: ClipDescription?): Boolean {
        val ex = d?.extras ?: return false
        if (android.os.Build.VERSION.SDK_INT >= 33 && ex.getBoolean(ClipDescription.EXTRA_IS_SENSITIVE, false)) return true
        return ex.getBoolean("android.content.extra.IS_SENSITIVE", false)
    }

    /** Only call while the app (or a focused transparent activity) is in the foreground; Android blocks background reads. */
    fun readText(c: Context): String? {
        val cm = c.getSystemService(ClipboardManager::class.java)
        val clip = cm.primaryClip?.takeIf { it.itemCount > 0 } ?: return null
        if (isSensitive(clip.description)) return null
        val item = clip.getItemAt(0)
        return item.coerceToText(c)?.toString()?.takeIf { it.isNotEmpty() }
    }

    /** What is on the clipboard right now, as far as an explicit "Paste" send cares. Never keeps the content. */
    sealed interface Read {
        data object Empty : Read
        data object Sensitive : Read
        data class Text(val text: String) : Read
        /** A `content://` item such as a copied image. */
        data class Content(val uri: android.net.Uri) : Read
    }

    /** Foreground only (Android blocks background reads). Clips marked sensitive are never read. */
    fun read(c: Context): Read {
        val clip = c.getSystemService(ClipboardManager::class.java).primaryClip?.takeIf { it.itemCount > 0 } ?: return Read.Empty
        if (isSensitive(clip.description)) return Read.Sensitive
        val item = clip.getItemAt(0)
        val uri = item.uri
        if (uri != null && uri.scheme == "content") {
            val type = runCatching { c.contentResolver.getType(uri) }.getOrNull()
            if (type != null && !type.startsWith("text/")) return Read.Content(uri)
        }
        val text = item.coerceToText(c)?.toString()?.takeIf { it.isNotEmpty() } ?: return Read.Empty
        return Read.Text(text)
    }

    /** Writes text that came from the Mac. Marked as synced first so the accessibility path doesn't send it back. */
    fun write(c: Context, text: String) {
        markSynced(text)
        Handler(Looper.getMainLooper()).post {
            runCatching { c.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("Mydroid", text)) }
        }
    }

    fun message(text: String): Message? {
        if (text.toByteArray(Charsets.UTF_8).size > MAX_BYTES) return null
        return Message.of("clip.set") { put("text", text) }
    }
}

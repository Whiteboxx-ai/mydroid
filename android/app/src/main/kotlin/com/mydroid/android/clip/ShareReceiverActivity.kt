package com.mydroid.android.clip

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import com.mydroid.android.manager
import kotlinx.serialization.json.put

/** "Send to Mac" share target: text becomes `clip.set`, files become `xfer.offer kind:file`. */
class ShareReceiverActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Files: stay open (invisibly) until they're copied; the read grant ends when this screen does.
        if (!handle(intent)) finish()
    }

    /** @return true when [finish] will be called once shared files are copied. */
    private fun handle(i: Intent): Boolean {
        val m = manager()
        if (!m.store.isPaired) { toast("Pair with your Mac first"); return false }
        m.start()
        val uris = ArrayList<Uri>()
        @Suppress("DEPRECATION")
        when (i.action) {
            Intent.ACTION_SEND -> {
                val u = if (Build.VERSION.SDK_INT >= 33) i.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java) else i.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                if (u != null) uris += u
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val l = if (Build.VERSION.SDK_INT >= 33) i.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java) else i.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                if (l != null) uris += l
            }
        }
        if (uris.isEmpty()) {
            val text = i.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            toast(sendText(m, text))
            return false
        }
        // Queued files wait for the Mac (up to a day), so there's no need to refuse while it's away.
        toast(m.sendUris(uris) { finish() })
        return true
    }

    private fun sendText(m: com.mydroid.android.net.ConnectionManager, text: String?): String {
        if (text.isNullOrEmpty()) return "Nothing to send"
        val url = com.mydroid.protocol.Links.safe(text)
        if (url != null) {
            // A single link goes to the Mac's browser, not its clipboard (PROTOCOL.md 7.4).
            return if (m.send(com.mydroid.protocol.Message.of("link.open") { put("url", url) })) "Sent to ${m.store.macName}" else "Your Mac isn't connected"
        }
        if (!m.settings.clipboard) return "Clipboard sharing is off on your Mac"
        val msg = Clipboard.message(text) ?: return "Text is too long to send"
        return if (m.send(msg)) "Sent to ${m.store.macName}" else "Your Mac isn't connected"
    }

    private fun toast(s: String) = Toast.makeText(applicationContext, s, Toast.LENGTH_SHORT).show()
}

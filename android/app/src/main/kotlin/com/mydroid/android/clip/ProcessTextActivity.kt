package com.mydroid.android.clip

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.widget.Toast
import com.mydroid.android.manager

/**
 * "Send to Mac" in the text-selection toolbar (ACTION_PROCESS_TEXT), next to Copy and Share. This is the
 * permission-free way to send phone text to the Mac: the user selected it and tapped us, so there is no clipboard
 * read and no accessibility service. A single http/https/mailto URL becomes `link.open`; anything else `clip.set`.
 * It is an explicit action, so it works even while clipboard sharing is off. No UI: it toasts and finishes.
 * Logs only the length.
 */
class ProcessTextActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val text = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)
        val msg = if (text.isNullOrEmpty()) "Nothing to send" else manager().sendSelectedText(text.toString())
        Log.i(TAG, "process_text len=${text?.length ?: 0} readonly=${intent.getBooleanExtra(Intent.EXTRA_PROCESS_TEXT_READONLY, false)}")
        Toast.makeText(applicationContext, msg, Toast.LENGTH_SHORT).show()
        // Editable fields get their own text back, untouched; read-only text needs no result.
        if (!intent.getBooleanExtra(Intent.EXTRA_PROCESS_TEXT_READONLY, false) && text != null) {
            setResult(RESULT_OK, Intent().putExtra(Intent.EXTRA_PROCESS_TEXT, text))
        }
        finish()
        overridePendingTransition(0, 0)
    }

    private companion object { const val TAG = "MydroidClip" }
}

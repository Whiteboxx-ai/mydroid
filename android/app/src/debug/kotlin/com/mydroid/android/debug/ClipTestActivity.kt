package com.mydroid.android.debug

import android.app.Activity
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat

/**
 * Debug-only. `am start -n com.whiteboxxai.mydroid/com.mydroid.android.debug.ClipTestActivity --ez auto true`:
 * focuses a text field with the keyboard up, "taps" Copy test text (which emits the accessibility click
 * event the service listens for) and logs whether the keyboard survived. Logs booleans only.
 */
class ClipTestActivity : Activity() {
    private lateinit var field: EditText
    private val h = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(48, 120, 48, 48) }
        field = EditText(this).apply { hint = "type here" }
        val copy = Button(this).apply { text = "Copy test text" }
        root.addView(field, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        root.addView(copy, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        setContentView(root)
        copy.setOnClickListener { Log.i(TAG, "copy button clicked") }
        if (intent.getBooleanExtra("auto", false)) {
            val withKeyboard = intent.getBooleanExtra("keyboard", true)
            h.postDelayed({
                if (withKeyboard) {
                    field.requestFocus()
                    ViewCompat.getWindowInsetsController(field)?.show(WindowInsetsCompat.Type.ime())
                }
            }, 600)
            h.postDelayed({
                Log.i(TAG, "ime before=${ime()} focused=${hasWindowFocus()}")
                if (intent.getBooleanExtra("setclip", true)) {
                    val cm = getSystemService(android.content.ClipboardManager::class.java)
                    cm.setPrimaryClip(android.content.ClipData.newPlainText("t", "mydroid-test-" + System.currentTimeMillis()))
                    Log.i(TAG, "test clip set len=${"mydroid-test-".length + 13}")
                }
                copy.performClick()
                // bg=true: leave right away so no Mydroid window is focused when the service reads (proves the overlay gives focus).
                if (intent.getBooleanExtra("bg", false)) h.postDelayed({ finish() }, 30)
            }, 2200)
            h.postDelayed({ Log.i(TAG, "ime after=${ime()} focused=${hasWindowFocus()}") }, 3200)
            h.postDelayed({ if (!isFinishing) finish() }, 4200)
        }
    }

    private fun ime(): Boolean = ViewCompat.getRootWindowInsets(field)?.isVisible(WindowInsetsCompat.Type.ime()) == true

    private companion object { const val TAG = "MydroidClipTest" }
}

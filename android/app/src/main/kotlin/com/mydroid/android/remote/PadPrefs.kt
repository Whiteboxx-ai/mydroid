package com.mydroid.android.remote

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import com.mydroid.protocol.TrackpadConfig

/** The pad's settings. Each change is saved at once and the pad picks it up on the next frame. */
@Stable
class PadSettings(context: Context?) {
    private val prefs = context?.applicationContext?.getSharedPreferences("remote_pad", Context.MODE_PRIVATE)

    var speed by mutableStateOf(prefs?.getFloat("speed", 1f) ?: 1f)
        private set
    var reverseScroll by mutableStateOf(prefs?.getBoolean("reverse", false) ?: false)
        private set
    var tapToClick by mutableStateOf(prefs?.getBoolean("tap", true) ?: true)
        private set
    /** The gesture tips on the pad stay until the first touch, and come back from the settings sheet. */
    var hintsSeen by mutableStateOf(prefs?.getBoolean("hints", false) ?: false)
        private set

    fun updateSpeed(v: Float) { speed = v.coerceIn(MIN_SPEED, MAX_SPEED); prefs?.edit()?.putFloat("speed", speed)?.apply() }
    fun updateReverseScroll(v: Boolean) { reverseScroll = v; prefs?.edit()?.putBoolean("reverse", v)?.apply() }
    fun updateTapToClick(v: Boolean) { tapToClick = v; prefs?.edit()?.putBoolean("tap", v)?.apply() }
    fun updateHintsSeen(v: Boolean) { hintsSeen = v; prefs?.edit()?.putBoolean("hints", v)?.apply() }

    fun config() = TrackpadConfig(speedScale = speed.toDouble(), reverseScroll = reverseScroll, tapToClick = tapToClick)

    companion object { const val MIN_SPEED = 0.5f; const val MAX_SPEED = 2.0f }
}

@Composable
fun rememberPadSettings(): PadSettings {
    val ctx = LocalContext.current
    return remember { PadSettings(ctx) }
}

package com.mydroid.android.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.mydroid.android.net.Link
import com.mydroid.android.net.UiState
import com.mydroid.android.remote.ArtPalette
import com.mydroid.android.remote.RemoteApi
import com.mydroid.protocol.MacMediaState
import com.mydroid.protocol.RemoteInput
import com.mydroid.protocol.RemoteWire
import kotlinx.coroutines.delay

/**
 * Playing: what Music or Spotify is playing on the Mac, with its cover, a seek bar and volume. Anything else on the Mac
 * still answers the media keys, which is what the empty state offers (PROTOCOL.md 16.3).
 */
@Composable
internal fun PlayingPane(s: UiState, api: RemoteApi, input: RemoteInput, insets: Modifier, fixedNow: Long? = null) {
    val connected = s.link == Link.Connected
    LaunchedEffect(connected) { if (connected) api.watchMedia(true) }
    DisposableEffect(api) { onDispose { api.watchMedia(false) } }
    val media = s.mac.media
    when {
        media != null && media.active -> NowPlaying(media, api, insets, fixedNow)
        media?.error == "automation" -> PlayingEmpty(input, api, insets, volume = media.volume, needsPermission = true)
        else -> PlayingEmpty(input, api, insets, volume = media?.volume, needsPermission = false, waiting = media == null && connected)
    }
}

// ---------------------------------------------------------------------------------------- something is playing

@Composable
private fun NowPlaying(m: MacMediaState, api: RemoteApi, insets: Modifier, fixedNow: Long?) {
    val cs = MaterialTheme.colorScheme
    val now by produceState(fixedNow ?: System.currentTimeMillis(), fixedNow) { if (fixedNow == null) while (true) { value = System.currentTimeMillis(); delay(500) } }
    val cover = remember(m.art) { m.art?.let { decode(it) } }
    val wash = remember(m.art) { cover?.let { washOf(it) } ?: listOf(cs.primary.toArgbInt()) }
    val base = Color(0xFF12100F)
    val white = Color.White

    Box(Modifier.fillMaxSize().background(base)) {
        // The cover's colours, faded into the dark. The first from the top, the second from the right, the third from the bottom.
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(wash[0]).copy(alpha = 0.85f), Color.Transparent), endY = 1500f)))
        wash.getOrNull(1)?.let { c -> Box(Modifier.fillMaxSize().background(Brush.radialGradient(listOf(Color(c).copy(alpha = 0.6f), Color.Transparent), center = androidx.compose.ui.geometry.Offset(1200f, 1100f), radius = 1100f))) }
        wash.getOrNull(2)?.let { c -> Box(Modifier.fillMaxSize().background(Brush.radialGradient(listOf(Color(c).copy(alpha = 0.7f), Color.Transparent), center = androidx.compose.ui.geometry.Offset(0f, 2200f), radius = 1300f))) }

        Column(Modifier.fillMaxSize().then(insets).padding(horizontal = 28.dp).padding(top = 8.dp, bottom = 12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                val side = minOf(LocalConfiguration.current.screenWidthDp - 56, 330).dp
                Box(Modifier.size(side).shadow(28.dp, RoundedCornerShape(28.dp)).clip(RoundedCornerShape(28.dp)).background(Color.White.copy(alpha = 0.08f)), contentAlignment = Alignment.Center) {
                    if (cover != null) Image(cover, "Cover of ${m.album.ifEmpty { m.title }}", Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                    else Icon(Glyphs.MusicNote, null, Modifier.size(88.dp), tint = white.copy(alpha = 0.5f))
                }
            }
            Spacer(Modifier.height(8.dp))
            Column(Modifier.fillMaxWidth()) {
                Text(m.title.ifEmpty { "Unknown title" }, color = white, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(listOf(m.artist, m.album).filter { it.isNotEmpty() }.joinToString(" · "), color = white.copy(alpha = 0.78f), style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Spacer(Modifier.height(6.dp))
            Scrubber(m, now, api, white)
            Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), horizontalArrangement = Arrangement.SpaceEvenly, verticalAlignment = Alignment.CenterVertically) {
                PlainTransport(Glyphs.SkipPrevious, "Previous track", white) { api.mediaCommand(RemoteWire.mediaPrev()) }
                Surface(
                    { api.mediaCommand(RemoteWire.mediaToggle()) }, Modifier.size(84.dp).semantics { contentDescription = if (m.playing) "Pause" else "Play" },
                    shape = CircleShape, color = white, contentColor = Color(0xFF1B1330), shadowElevation = 8.dp,
                ) { Box(contentAlignment = Alignment.Center) { Icon(if (m.playing) Glyphs.Pause else Glyphs.Play, null, Modifier.size(40.dp)) } }
                PlainTransport(Glyphs.SkipNext, "Next track", white) { api.mediaCommand(RemoteWire.mediaNext()) }
            }
            VolumeRow(m.volume, api, white)
        }
        // The source, small, top right.
        Surface(Modifier.align(Alignment.TopEnd).then(insets).padding(top = 8.dp, end = 16.dp), shape = RoundedCornerShape(16.dp), color = white.copy(alpha = 0.16f)) {
            Row(Modifier.padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(Glyphs.MusicNote, null, Modifier.size(16.dp), tint = white); Text(m.app, color = white, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

@Composable
private fun PlainTransport(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, tint: Color, onClick: () -> Unit) {
    IconButton(onClick, Modifier.size(64.dp).semantics { contentDescription = label }) { Icon(icon, null, Modifier.size(38.dp), tint = tint) }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Scrubber(m: MacMediaState, now: Long, api: RemoteApi, white: Color) {
    val pos = m.positionAt(now)
    var dragging by remember { mutableStateOf<Float?>(null) }
    val fraction = if (m.duration > 0) (pos.toFloat() / m.duration).coerceIn(0f, 1f) else 0f
    val shown = dragging ?: fraction
    val colors = SliderDefaults.colors(thumbColor = white, activeTrackColor = white, inactiveTrackColor = white.copy(alpha = 0.25f), disabledThumbColor = white.copy(alpha = 0.4f), disabledActiveTrackColor = white.copy(alpha = 0.4f), disabledInactiveTrackColor = white.copy(alpha = 0.2f))
    Column(Modifier.fillMaxWidth()) {
        Slider(
            shown, { dragging = it }, Modifier.fillMaxWidth().semantics { contentDescription = "Position" }, enabled = m.canSeek && m.duration > 0,
            onValueChangeFinished = { dragging?.let { api.mediaCommand(RemoteWire.mediaSeek((it * m.duration).toLong())) }; dragging = null },
            colors = colors,
        )
        val shownMs = dragging?.let { (it * m.duration).toLong() } ?: pos
        Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(formatElapsed(shownMs), color = white.copy(alpha = 0.78f), style = MaterialTheme.typography.labelMedium)
            Text("-" + formatElapsed((m.duration - shownMs).coerceAtLeast(0)), color = white.copy(alpha = 0.78f), style = MaterialTheme.typography.labelMedium)
        }
    }
}

/** The Mac's output volume. Changes go out as you drag, at most ten a second. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun VolumeRow(volume: Double?, api: RemoteApi, tint: Color, enabled: Boolean = true) {
    var local by remember { mutableStateOf<Float?>(null) }
    var lastSent by remember { mutableLongStateOf(0L) }
    val value = local ?: (volume?.toFloat() ?: 0.5f)
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Icon(Glyphs.VolumeDown, null, Modifier.size(22.dp), tint = tint.copy(alpha = 0.8f))
        Slider(
            value, {
                local = it
                val t = System.currentTimeMillis()
                if (t - lastSent >= 100) { lastSent = t; api.mediaCommand(RemoteWire.mediaVolume(it.toDouble())) }
            },
            Modifier.weight(1f).semantics { contentDescription = "Volume on your Mac" }, enabled = enabled,
            onValueChangeFinished = { local?.let { api.mediaCommand(RemoteWire.mediaVolume(it.toDouble())) }; local = null },
            colors = SliderDefaults.colors(thumbColor = tint, activeTrackColor = tint.copy(alpha = 0.9f), inactiveTrackColor = tint.copy(alpha = 0.25f)),
        )
        Icon(Glyphs.VolumeUp, null, Modifier.size(22.dp), tint = tint.copy(alpha = 0.8f))
    }
}

// ---------------------------------------------------------------------------------------- nothing to show yet

@Composable
private fun PlayingEmpty(input: RemoteInput, api: RemoteApi, insets: Modifier, volume: Double?, needsPermission: Boolean, waiting: Boolean = false) {
    val cs = MaterialTheme.colorScheme
    Column(Modifier.fillMaxSize().then(insets).padding(horizontal = 20.dp).padding(bottom = 12.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(20.dp)) {
        Spacer(Modifier.height(12.dp))
        Box(Modifier.size(180.dp).clip(RoundedCornerShape(28.dp)).background(cs.surfaceContainerHigh), contentAlignment = Alignment.Center) {
            if (waiting) CircularProgressIndicator(Modifier.size(32.dp), strokeWidth = 3.dp)
            else Icon(Glyphs.MusicNote, null, Modifier.size(72.dp), tint = cs.onSurfaceVariant)
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(
                when { needsPermission -> "Allow Mydroid on your Mac"; waiting -> "Looking for music…"; else -> "Nothing playing" },
                style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center,
            )
            Text(
                when {
                    needsPermission -> "Your Mac asks whether Mydroid may control Music or Spotify. Choose Allow, or turn it on in System Settings › Privacy & Security › Automation."
                    waiting -> "Checking Music and Spotify on your Mac."
                    else -> "Start a song on your Mac. Song details show for Music and Spotify; anything else still answers the keys below."
                },
                style = MaterialTheme.typography.bodyMedium, color = cs.onSurfaceVariant, textAlign = TextAlign.Center, modifier = Modifier.widthIn(max = 320.dp),
            )
        }
        if (!needsPermission && !waiting) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Button({ api.launchApp(com.mydroid.protocol.MacApp("com.apple.Music", "Music")) }, Modifier.weight(1f).height(52.dp)) { Text("Open Music") }
                FilledTonalButton({ api.launchApp(com.mydroid.protocol.MacApp("com.spotify.client", "Spotify")) }, Modifier.weight(1f).height(52.dp)) { Text("Open Spotify") }
            }
        }
        Spacer(Modifier.weight(1f))
        // Keys that work for any app on the Mac.
        Surface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(28.dp), color = cs.surfaceContainerLow) {
            Column(Modifier.padding(horizontal = 12.dp, vertical = 14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly, verticalAlignment = Alignment.CenterVertically) {
                    PressButton({ input.media("prev") }, Modifier.size(60.dp), cs.surfaceContainerHighest, cs.onSurface, CircleShape, "Previous track") { Icon(Glyphs.SkipPrevious, null, Modifier.size(28.dp)) }
                    PressButton({ input.media("playpause") }, Modifier.size(76.dp), cs.primary, cs.onPrimary, CircleShape, "Play or pause") { Icon(Glyphs.Play, null, Modifier.size(34.dp)) }
                    PressButton({ input.media("next") }, Modifier.size(60.dp), cs.surfaceContainerHighest, cs.onSurface, CircleShape, "Next track") { Icon(Glyphs.SkipNext, null, Modifier.size(28.dp)) }
                }
                VolumeRow(volume, api, cs.onSurface)
            }
        }
    }
}

// ---------------------------------------------------------------------------------------- cover helpers

private fun decode(bytes: ByteArray): ImageBitmap? = runCatching { BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap() }.getOrNull()

private fun washOf(cover: ImageBitmap): List<Int> {
    val small = Bitmap.createScaledBitmap(cover.asAndroidBitmap(), 24, 24, true)
    val px = IntArray(24 * 24)
    small.getPixels(px, 0, 24, 0, 0, 24, 24)
    return ArtPalette.wash(px)
}

/** The theme's accent, pulled down so white text stays readable on top of it. */
private fun Color.toArgbInt(): Int = Color(red * 0.55f, green * 0.55f, blue * 0.55f).toArgb()

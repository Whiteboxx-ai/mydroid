package com.mydroid.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.mydroid.android.net.Link
import com.mydroid.android.net.UiState
import com.mydroid.android.remote.RemoteApi
import com.mydroid.android.remote.rememberPadSettings
import com.mydroid.protocol.RemoteInput

/** The four places in Remote. What opens first depends on what the Mac is doing (see [RemoteTab.fromName]). */
internal enum class RemoteTab(val label: String) {
    Pad("Pad"), Present("Present"), Playing("Playing"), Open("Open");

    companion object {
        /** Names the app has used for these places, including the old tab names a notification may still carry. */
        fun fromName(name: String?): RemoteTab? = when (name?.lowercase()) {
            "pad", "trackpad" -> Pad
            "present", "presenter" -> Present
            "playing", "media" -> Playing
            "open" -> Open
            else -> null
        }
    }
}

private enum class Block { Away, Allow }

// ---------------------------------------------------------------------------------------- screen

/**
 * Remote for the Mac (PROTOCOL.md 10 and 16): Pad, Present, Playing and Open. [now] is fixed in tests and screenshots;
 * live, it ticks once a second while the screen is visible. [timerStart] is when the presentation timer began.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun RemoteScreen(
    s: UiState, api: RemoteApi, tab: RemoteTab, onTab: (RemoteTab) -> Unit, onBack: () -> Unit,
    timerStart: Long, onTimerReset: () -> Unit, now: Long? = null,
    /** Tests and previews: files to show instead of asking the Mac. */
    previewHits: List<com.mydroid.protocol.FsHit>? = null,
) {
    val cs = MaterialTheme.colorScheme
    val connected = s.link == Link.Connected
    val accessibility = s.mac.remote?.accessibility
    val block = when {
        !connected -> Block.Away
        accessibility == false && (tab == RemoteTab.Pad || tab == RemoteTab.Present) -> Block.Allow
        else -> null
    }
    // The Mac lacks Accessibility: ask it to show its prompt. Again if the connection came back and it still isn't allowed.
    LaunchedEffect(connected, accessibility) { if (connected && accessibility == false) api.ask() }

    val view = LocalView.current
    DisposableEffect(view) {
        val before = view.keepScreenOn
        view.keepScreenOn = true // a remote that dims while you hold it is no remote
        onDispose { view.keepScreenOn = before }
    }
    val input = remember(api) { RemoteInput(api::send) }
    var typing by rememberSaveable { mutableStateOf(false) }
    var padSettingsOpen by rememberSaveable { mutableStateOf(false) }
    val padSettings = rememberPadSettings()

    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Top + WindowInsetsSides.Horizontal)).padding(start = 6.dp, end = 6.dp, top = 4.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onBack, Modifier.size(48.dp).semantics { contentDescription = "Back" }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, null) }
            Spacer(Modifier.width(2.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    if (typing && tab == RemoteTab.Pad) "Typing on your Mac" else "Remote",
                    style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold,
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(8.dp).clip(CircleShape).background(if (connected) Color(0xFF1A8F3C) else cs.outline))
                    Spacer(Modifier.width(6.dp))
                    val name = s.macName.replaceFirstChar { it.uppercase() }
                    Text(
                        if (connected) name else "Waiting for $name", style = MaterialTheme.typography.bodySmall, color = cs.onSurfaceVariant,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            if (tab == RemoteTab.Pad && !typing) {
                IconButton({ padSettingsOpen = true }, Modifier.size(48.dp).semantics { contentDescription = "Pad settings" }) { Icon(Glyphs.Tune, null) }
            }
        }
        Box(Modifier.weight(1f).fillMaxWidth()) {
            val bottom = Modifier.windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom))
            when (tab) {
                RemoteTab.Pad -> PadPane(api, input, typing, { typing = it }, bottom, padSettings)
                RemoteTab.Present -> PresentPane(s, api, timerStart, onTimerReset, now, onBrowse = { onTab(RemoteTab.Open) }, insets = bottom, previewDecks = previewHits?.filter { com.mydroid.protocol.Decks.isDeck(it.entry.name) })
                RemoteTab.Playing -> PlayingPane(s, api, input, bottom, now)
                RemoteTab.Open -> OpenPane(s, api, bottom, previewHits)
            }
            if (block != null) BlockOverlay(block, api, s.mac.remoteAt)
        }
        // Typing needs the room, and a slideshow in progress needs fewer ways to tap something by accident.
        if (!(typing && tab == RemoteTab.Pad)) {
            NavigationBar(containerColor = cs.surfaceContainerLow) {
                RemoteTab.entries.forEach { t ->
                    NavigationBarItem(
                        selected = t == tab, onClick = { onTab(t) },
                        icon = { Icon(t.glyph(), null) }, label = { Text(t.label) },
                    )
                }
            }
        }
    }
    if (padSettingsOpen) PadSettingsSheet(padSettings) { padSettingsOpen = false }
}

private fun RemoteTab.glyph() = when (this) {
    RemoteTab.Pad -> Glyphs.Mouse
    RemoteTab.Present -> Glyphs.Slideshow
    RemoteTab.Playing -> Glyphs.MusicNote
    RemoteTab.Open -> Glyphs.Apps
}

/**
 * Calm, not alarming: says what is needed, and clears itself the moment `remote.state` flips. While it waits for the Mac's
 * permission it asks again every few seconds (the Mac checks again each time and brings its card back if it was closed),
 * and after a while says what to do when the switch looks on but nothing changes.
 */
@Composable
private fun BlockOverlay(block: Block, api: RemoteApi, answeredAt: Long) {
    val cs = MaterialTheme.colorScheme
    var stuck by remember(block) { mutableStateOf(false) }
    LaunchedEffect(block) {
        if (block != Block.Allow) return@LaunchedEffect
        var n = 0
        while (true) {
            kotlinx.coroutines.delay(6_000)
            api.ask()
            if (++n >= 2) stuck = true
        }
    }
    Box(
        Modifier.fillMaxSize().background(cs.background.copy(alpha = 0.94f))
            // Swallow every touch so nothing reaches the pane underneath.
            .pointerInput(Unit) { awaitPointerEventScope { while (true) awaitPointerEvent().changes.forEach { it.consume() } } },
        contentAlignment = Alignment.Center,
    ) {
        Card28(Modifier.padding(horizontal = 28.dp), color = cs.surfaceContainerHigh) {
            Column(Modifier.padding(horizontal = 24.dp, vertical = 28.dp).fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(Modifier.size(64.dp).clip(CircleShape).background(cs.primaryContainer), contentAlignment = Alignment.Center) {
                    Icon(Glyphs.Laptop, null, Modifier.size(32.dp), tint = cs.onPrimaryContainer)
                }
                Spacer(Modifier.height(4.dp))
                Text(
                    if (block == Block.Allow) "Allow Mydroid on your Mac" else "Your Mac isn't connected",
                    style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center,
                )
                Text(
                    if (block == Block.Allow) "On your Mac, turn on Mydroid in System Settings › Privacy & Security › Accessibility."
                    else "Remote works when it's back",
                    style = MaterialTheme.typography.bodyMedium, color = cs.onSurfaceVariant, textAlign = TextAlign.Center,
                )
                if (block == Block.Allow) {
                    Spacer(Modifier.height(4.dp))
                    // What the Mac last said, and how long ago, so "your Mac says no" is never confused with "your Mac isn't answering".
                    val now by produceState(System.currentTimeMillis()) { while (true) { value = System.currentTimeMillis(); kotlinx.coroutines.delay(1000) } }
                    val ago = if (answeredAt > 0) ((now - answeredAt) / 1000).coerceAtLeast(0) else null
                    val silent = ago == null || ago > 15
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Box(Modifier.size(8.dp).clip(CircleShape).background(if (silent) cs.error else cs.tertiary))
                        Text(
                            if (silent) "Your Mac isn't answering. Is Mydroid open on it?" else "Your Mac says: not allowed yet · checked ${if (ago!! < 2) "just now" else "$ago s ago"}",
                            style = MaterialTheme.typography.labelMedium, color = cs.onSurfaceVariant,
                        )
                    }
                    if (!stuck) CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.5.dp)
                    else {
                        Text(
                            "Still waiting? If Mydroid is already switched on, click Reset on the card on your Mac. macOS ties the switch to one exact copy of the app.",
                            style = MaterialTheme.typography.bodySmall, color = cs.onSurfaceVariant, textAlign = TextAlign.Center,
                        )
                    }
                    FilledTonalButton({ api.ask() }) { Text("Show it on my Mac again") }
                }
            }
        }
    }
}

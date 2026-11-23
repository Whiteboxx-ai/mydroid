package com.mydroid.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import com.mydroid.android.net.Link
import com.mydroid.android.net.UiState
import com.mydroid.android.remote.LaserPointer
import com.mydroid.android.remote.LaserSensor
import com.mydroid.android.remote.RemoteApi
import com.mydroid.protocol.Decks
import com.mydroid.protocol.FsHit
import com.mydroid.protocol.RemoteWire
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.text.DateFormat
import java.util.Date

/**
 * Present: pick a deck and play it, or run the slideshow that is going. The Mac reports where the slideshow is only while
 * this tab is open (PROTOCOL.md 16.2).
 */
@Composable
internal fun PresentPane(
    s: UiState, api: RemoteApi, timerStart: Long, onTimerReset: () -> Unit, fixedNow: Long?, onBrowse: () -> Unit, insets: Modifier,
    previewDecks: List<FsHit>? = null,
) {
    val connected = s.link == Link.Connected
    LaunchedEffect(connected) { if (connected) api.watchPresent(true) }
    DisposableEffect(api) { onDispose { api.watchPresent(false) } }
    val live = s.mac.present?.active == true || s.mac.remote?.presenting != null
    if (live) LivePresenter(s, api, timerStart, onTimerReset, fixedNow, insets) else DeckPicker(s, api, onBrowse, insets, previewDecks)
}

// ---------------------------------------------------------------------------------------- before the show

@Composable
private fun DeckPicker(s: UiState, api: RemoteApi, onBrowse: () -> Unit, insets: Modifier, previewDecks: List<FsHit>?) {
    val cs = MaterialTheme.colorScheme
    val connected = s.link == Link.Connected
    var decks by remember { mutableStateOf(previewDecks) }
    var failed by remember { mutableStateOf(false) }
    LaunchedEffect(connected) {
        if (previewDecks != null || !connected) return@LaunchedEffect
        val all = withContext(Dispatchers.IO) { api.findFiles("") }
        failed = all == null
        decks = all?.filter { !it.entry.dir && Decks.isDeck(it.entry.name) }?.sortedByDescending { it.entry.mtime }
    }
    var selectedPath by rememberSaveable { mutableStateOf<String?>(null) }
    val selected = decks?.firstOrNull { it.path == selectedPath } ?: decks?.firstOrNull()
    var linkDialog by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxSize().then(insets).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Column {
            Text("Present from your phone", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold)
            Text("Pick a deck. It opens and plays on your Mac.", style = MaterialTheme.typography.bodyLarge, color = cs.onSurfaceVariant)
        }
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            SectionLabel("Recent on your Mac")
            when {
                decks == null && !failed && connected -> Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(Modifier.size(28.dp), strokeWidth = 3.dp) }
                decks.isNullOrEmpty() -> Text(
                    if (failed) "Couldn't read your Mac's recent files. Turn on file sharing in Mydroid for Mac, or browse for a deck."
                    else "No recent presentations in the folders you share. Browse your files to pick one.",
                    style = MaterialTheme.typography.bodyMedium, color = cs.onSurfaceVariant, modifier = Modifier.padding(horizontal = 4.dp),
                )
                else -> decks!!.take(6).forEach { d ->
                    if (d.path == selected?.path) SelectedDeck(d, api) else DeckRow(d) { selectedPath = d.path }
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilledTonalButton(onBrowse, Modifier.weight(1f).height(52.dp)) { Icon(Glyphs.Folder, null, Modifier.size(20.dp)); Spacer(Modifier.width(8.dp)); Text("Browse files") }
            FilledTonalButton({ linkDialog = true }, Modifier.weight(1f).height(52.dp)) { Icon(Glyphs.Link, null, Modifier.size(20.dp)); Spacer(Modifier.width(8.dp)); Text("Slides link") }
        }
    }
    if (linkDialog) SlidesLinkDialog(onDismiss = { linkDialog = false }, onOpen = { api.openLink(it); linkDialog = false })
}

@Composable
private fun SelectedDeck(d: FsHit, api: RemoteApi) {
    val cs = MaterialTheme.colorScheme
    Surface(shape = RoundedCornerShape(28.dp), color = cs.primaryContainer, contentColor = cs.onPrimaryContainer) {
        Column(Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Box(Modifier.size(48.dp).clip(RoundedCornerShape(14.dp)).background(cs.surface), contentAlignment = Alignment.Center) { Icon(Glyphs.Slideshow, null, Modifier.size(26.dp), tint = cs.primary) }
                Column(Modifier.weight(1f)) {
                    Text(Decks.title(d.entry.name), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text("${Decks.kind(d.entry.name)} · ${d.path.substringBeforeLast('/', "").ifEmpty { "Top level" }}", style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            Spacer(Modifier.height(14.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button({ api.startPresentation(d, play = true) }, Modifier.weight(1f).height(52.dp)) {
                    Icon(Glyphs.Play, null, Modifier.size(20.dp)); Spacer(Modifier.width(8.dp)); Text("Play from start")
                }
                FilledTonalButton({ api.startPresentation(d, play = false) }, Modifier.height(52.dp), colors = ButtonDefaults.filledTonalButtonColors(containerColor = cs.surface.copy(alpha = 0.7f), contentColor = cs.onSurface)) { Text("Just open") }
            }
        }
    }
}

@Composable
private fun DeckRow(d: FsHit, onClick: () -> Unit) {
    val cs = MaterialTheme.colorScheme
    Surface(onClick, shape = RoundedCornerShape(20.dp), color = cs.surfaceContainerLow) {
        Row(Modifier.padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            FileTile(d.entry.name, Modifier.size(44.dp))
            Column(Modifier.weight(1f)) {
                Text(Decks.title(d.entry.name), style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text("${d.path.substringBeforeLast('/', "").ifEmpty { "Top level" }} · ${relativeDay(d.entry.mtime)}", style = MaterialTheme.typography.bodySmall, color = cs.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Icon(Glyphs.ChevronRight, null, tint = cs.onSurfaceVariant)
        }
    }
}

@Composable
private fun SlidesLinkDialog(onDismiss: () -> Unit, onOpen: (String) -> Unit) {
    var text by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Open a slides link on your Mac") },
        text = {
            OutlinedTextField(text, { text = it }, singleLine = true, label = { Text("Link") }, placeholder = { Text("https://docs.google.com/presentation/…") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
        },
        confirmButton = { TextButton({ onOpen(text.trim()) }, enabled = text.trim().startsWith("http")) { Text("Open") } },
        dismissButton = { TextButton(onDismiss) { Text("Cancel") } },
    )
}

// ---------------------------------------------------------------------------------------- during the show

@Composable
private fun LivePresenter(s: UiState, api: RemoteApi, timerStart: Long, onTimerReset: () -> Unit, fixedNow: Long?, insets: Modifier) {
    val cs = MaterialTheme.colorScheme
    val ctx = LocalContext.current
    val clock = fixedNow ?: rememberSecondClock()
    val info = s.mac.present
    val app = info?.app ?: s.mac.remote?.presenting?.app?.takeIf { it.isNotBlank() }
    fun go(next: Boolean) = api.send(RemoteWire.key(if (next) "right" else "left"))

    // While this screen is up the volume buttons are the clicker: down = next, up = back.
    DisposableEffect(api) {
        api.volumeKeys { up -> go(next = !up) }
        onDispose { api.volumeKeys(null) }
    }
    val laser = remember(api) { LaserPointer(LaserSensor(ctx), api::send) }
    val laserOk = api.laserPreview ?: laser.available
    LifecycleEventEffect(Lifecycle.Event.ON_PAUSE) { laser.release() }
    DisposableEffect(laser) { onDispose { laser.release() } }
    var lasering by remember { mutableStateOf(false) }
    var blackedOut by remember { mutableStateOf(false) }
    var bigNotes by rememberSaveable { mutableStateOf(false) }

    Column(Modifier.fillMaxSize().then(insets).padding(horizontal = 16.dp).padding(bottom = 12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        // Where you are, and how long you've been at it.
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.SpaceBetween) {
            Column {
                Text(if (app != null) "Presenting in $app" else "Presenting on your Mac", style = MaterialTheme.typography.labelLarge, color = cs.onSurfaceVariant)
                if (info?.index != null) {
                    Row(verticalAlignment = Alignment.Bottom) {
                        Text("${info.index}", fontSize = 52.sp, lineHeight = 56.sp, fontWeight = FontWeight.SemiBold)
                        if (info.count != null) Text("  of ${info.count}", style = MaterialTheme.typography.titleLarge, color = cs.onSurfaceVariant, modifier = Modifier.padding(bottom = 8.dp))
                    }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TimeChip("Elapsed", formatElapsed(clock - timerStart), Modifier.semantics { contentDescription = "Elapsed ${formatElapsed(clock - timerStart)}. Tap to reset." }, onTimerReset)
                TimeChip("Time", DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(clock)))
            }
        }

        val title = info?.title
        if (title != null) {
            Surface(shape = RoundedCornerShape(20.dp), color = cs.surfaceContainerHigh, modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(horizontal = 18.dp, vertical = 14.dp)) {
                    Text("NOW", style = MaterialTheme.typography.labelSmall, color = cs.onSurfaceVariant)
                    Text(title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
            }
        }

        // Speaker notes take the room that is left. Without them the card says why.
        Surface(Modifier.weight(1f).fillMaxWidth(), shape = RoundedCornerShape(20.dp), color = cs.surfaceContainerLow) {
            Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("NOTES", style = MaterialTheme.typography.labelSmall, color = cs.onSurfaceVariant)
                    TextButton({ bigNotes = !bigNotes }, contentPadding = PaddingValues(horizontal = 8.dp)) { Text(if (bigNotes) "Smaller text" else "Larger text") }
                }
                val notes = info?.notes
                when {
                    notes != null -> Text(notes, fontSize = if (bigNotes) 24.sp else 19.sp, lineHeight = if (bigNotes) 33.sp else 27.sp, modifier = Modifier.verticalScroll(rememberScrollState()))
                    info?.error == "automation" -> Text(
                        "Allow Mydroid to control ${app ?: "the app"} on your Mac to see slide numbers and notes here: System Settings › Privacy & Security › Automation.",
                        style = MaterialTheme.typography.bodyMedium, color = cs.onSurfaceVariant,
                    )
                    info?.index != null -> Text("No notes on this slide.", style = MaterialTheme.typography.bodyMedium, color = cs.onSurfaceVariant)
                    else -> Text("Slide details and notes show for Keynote and PowerPoint.", style = MaterialTheme.typography.bodyMedium, color = cs.onSurfaceVariant)
                }
            }
        }

        Row(Modifier.fillMaxWidth().height(104.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            PressButton({ go(false) }, Modifier.weight(1f).fillMaxHeight(), cs.secondaryContainer, cs.onSecondaryContainer, RoundedCornerShape(32.dp), "Previous slide") {
                Icon(Glyphs.ArrowLeft, null, Modifier.size(44.dp))
            }
            PressButton({ go(true) }, Modifier.weight(2f).fillMaxHeight(), cs.primary, cs.onPrimary, RoundedCornerShape(32.dp), "Next slide") {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("Next", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
                    Icon(Glyphs.ArrowRight, null, Modifier.size(40.dp))
                }
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            val red = Color(0xFFD93025)
            PressButton(
                onPress = {}, modifier = Modifier.weight(1.4f).height(56.dp),
                container = if (lasering) red else cs.surfaceContainerHigh, content = if (lasering) Color.White else cs.onSurface,
                shape = RoundedCornerShape(28.dp), description = "Laser pointer. Hold, then move your phone.",
                custom = { pressed ->
                    if (!laserOk) return@PressButton
                    if (pressed) { lasering = true; laser.press() } else { lasering = false; laser.release() }
                },
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(Glyphs.Target, null, Modifier.size(22.dp), tint = if (lasering) Color.White else red)
                    Text(if (!laserOk) "No motion sensor" else if (lasering) "Move to aim" else "Hold for laser", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                }
            }
            PressButton(
                { api.send(RemoteWire.key("b")); blackedOut = !blackedOut }, Modifier.weight(1f).height(56.dp),
                if (blackedOut) cs.inverseSurface else cs.surfaceContainerHigh, if (blackedOut) cs.inverseOnSurface else cs.onSurface,
                RoundedCornerShape(28.dp), if (blackedOut) "Bring the slide back" else "Black out the screen",
            ) { Text(if (blackedOut) "Show" else "Black", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold) }
        }
        Text("Volume buttons change slides", Modifier.fillMaxWidth(), style = MaterialTheme.typography.bodySmall, color = cs.onSurfaceVariant, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
    }
}

@Composable
private fun TimeChip(label: String, value: String, modifier: Modifier = Modifier, onClick: (() -> Unit)? = null) {
    val cs = MaterialTheme.colorScheme
    val body: @Composable () -> Unit = {
        Column(Modifier.padding(horizontal = 12.dp, vertical = 6.dp), horizontalAlignment = Alignment.End) {
            Text(label.uppercase(), style = MaterialTheme.typography.labelSmall, color = cs.onSurfaceVariant)
            Text(value, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        }
    }
    if (onClick != null) Surface(onClick, modifier, shape = RoundedCornerShape(16.dp), color = cs.surfaceContainerLow, content = body)
    else Surface(modifier, shape = RoundedCornerShape(16.dp), color = cs.surfaceContainerLow, content = body)
}

// ---------------------------------------------------------------------------------------- shared with Open

/** A file's type as a small tile: the extension, tinted by kind. */
@Composable
internal fun FileTile(name: String, modifier: Modifier = Modifier) {
    val cs = MaterialTheme.colorScheme
    val ext = name.substringAfterLast('.', "").uppercase().take(4)
    val (bg, fg) = when (name.substringAfterLast('.', "").lowercase()) {
        "key", "pptx", "ppt", "ppsx", "odp" -> cs.tertiaryContainer to cs.onTertiaryContainer
        "pdf" -> cs.errorContainer to cs.onErrorContainer
        "png", "jpg", "jpeg", "heic", "gif", "webp" -> cs.secondaryContainer to cs.onSecondaryContainer
        else -> cs.surfaceContainerHighest to cs.onSurfaceVariant
    }
    Box(modifier.clip(RoundedCornerShape(12.dp)).background(bg), contentAlignment = Alignment.Center) {
        Text(ext.ifEmpty { "FILE" }, color = fg, style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold, maxLines = 1)
    }
}

internal fun relativeDay(mtimeMs: Long, now: Long = System.currentTimeMillis()): String {
    val days = ((now - mtimeMs) / 86_400_000L).toInt()
    return when {
        mtimeMs <= 0 -> ""
        days <= 0 -> "Today"
        days == 1 -> "Yesterday"
        days < 7 -> "$days days ago"
        else -> DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(mtimeMs))
    }
}

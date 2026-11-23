package com.mydroid.android.ui

import android.os.Build
import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.mydroid.android.*
import com.mydroid.android.fix.Oem
import com.mydroid.android.net.Link
import com.mydroid.android.net.UiState
import com.mydroid.android.transfers.*
import com.mydroid.protocol.Links
import java.util.Calendar

// ---------------------------------------------------------------------------------------- attention

/** Something that actually needs fixing. [name] is the short label, [problem] says what is wrong. */
internal class Attention(val id: String, val name: String, val problem: String, val action: String, val run: () -> Unit)

/** What is broken right now, judged only from [FeatureReport]. Optional extras (nearby Mac, codes from apps) stay in Settings. */
internal fun attentionItems(s: UiState, a: Actions, killedAt: Long?, now: Long): List<Attention> {
    val set = s.settings ?: return emptyList()
    val r = s.report
    return buildList {
        if (set.notifications && r.state(Feature.Notifications) != FeatureState.On) add(Attention("notif", "Notifications", "Needs notification access", "Allow", a.allowNotificationAccess))
        if (set.notifications && r.otp != FeatureState.On) add(Attention("otp", "Verification codes", "Codes can't reach your Mac", "Allow", a.allowSms))
        if (set.photos && r.state(Feature.Photos) != FeatureState.On) add(Attention("photos", "Photos", "Needs photo access", "Allow", a.allowPhotos))
        else if (set.photos && r.photosPartial) add(Attention("photos", "Photos", "Only some photos are shared", "Allow all", a.allowPhotos))
        if (set.calls && r.state(Feature.Calls) != FeatureState.On) add(Attention("calls", "Calls", "Needs phone access", "Allow", a.allowCalls))
        if (set.calls && !r.dial) add(Attention("dial", "Call from your Mac", "Needs permission", "Allow", a.allowDial))
        if (set.smsHistory && r.state(Feature.Sms) != FeatureState.On) add(Attention("sms", "Messages", "Needs message access", "Allow", a.allowSmsHistory))
        if (set.walkAway && r.walkAway == com.mydroid.android.walkaway.WalkAwayStatus.NeedsPermission) add(Attention("walkaway", "Walk-away lock", "Needs Nearby devices", "Allow", a.allowWalkAway))
        when {
            r.backgroundRestricted -> add(Attention("battery", "Stay connected", "Android may pause Mydroid", "Fix", a.allowBattery))
            killedAt != null -> add(Attention("oem", "Stay connected", "${Oem.brandName} closed Mydroid ${ago(killedAt, now)}", "Fix", a.openOem))
        }
    }
}

// ---------------------------------------------------------------------------------------- home

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun HomeScreen(s: UiState, a: Actions, now: Long, onSettings: () -> Unit, animate: Boolean = true, onRemote: () -> Unit = {}, onAuth: () -> Unit = {}) {
    val ctx = LocalContext.current
    val connected = s.link == Link.Connected
    val killedAt = remember(s.oemOpenedAt, now) { runCatching { Oem.needsAutoStart(ctx, s.oemOpenedAt) }.getOrNull() }
    val items = remember(s, killedAt, now) { attentionItems(s, a, killedAt, now) }
    var showText by rememberSaveable { mutableStateOf(false) }
    var showFixes by remember { mutableStateOf(false) }
    var showShortcuts by rememberSaveable { mutableStateOf(false) }
    val snack = remember { SnackbarHostState() }
    LaunchedEffect(s.notice) {
        val n = s.notice ?: return@LaunchedEffect
        a.consumeNotice()
        snack.showSnackbar(n, duration = SnackbarDuration.Short)
    }

    Box(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize()) {
            HomeHeader(s, connected, now, onSettings, animate)
            Column(
                Modifier.weight(1f).verticalScroll(rememberScrollState())
                    .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom))
                    .padding(horizontal = 20.dp).padding(top = 12.dp, bottom = 28.dp),
                verticalArrangement = Arrangement.spacedBy(20.dp),
            ) {
                AnimatedVisibility(items.isNotEmpty(), enter = fadeIn() + expandVertically(), exit = fadeOut() + shrinkVertically()) {
                    AttentionBanner(items) { if (items.size == 1) items[0].run() else showFixes = true }
                }
                SendCard(s, a, connected, onText = { showText = true })
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    SectionLabel("Your Mac")
                    MacCard(
                        s.mac, connected, a.mac,
                        onShortcuts = { showShortcuts = true; a.mac.loadShortcuts() }, onRemote = onRemote, onFiles = a.openMacFiles,
                        auth = s.auth, onAuth = onAuth,
                    )
                }
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    SectionLabel("Activity")
                    ActivityCard(s, now, onSend = a.pickFiles)
                }
            }
        }
        SnackbarHost(
            snack,
            Modifier.align(Alignment.BottomCenter).windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Bottom + WindowInsetsSides.Horizontal)).padding(16.dp),
        )
    }

    if (showText) {
        val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
        ModalBottomSheet(onDismissRequest = { showText = false }, sheetState = sheet) {
            SendTextContent(connected = connected, macName = s.macName, onSend = { showText = false; a.sendText(it) }, autoFocus = true)
        }
    }
    if (showShortcuts) {
        ModalBottomSheet(onDismissRequest = { showShortcuts = false }) {
            ShortcutsContent(
                s.mac, onRun = { showShortcuts = false; a.mac.runShortcut(it) }, onStar = a.mac.toggleFavorite, onRetry = a.mac.loadShortcuts,
            )
        }
    }
    if (showFixes) {
        ModalBottomSheet(onDismissRequest = { showFixes = false }) {
            FixList(items, onRun = { showFixes = false; it.run() })
        }
    }
}

@Composable
private fun HomeHeader(s: UiState, connected: Boolean, now: Long, onSettings: () -> Unit, animate: Boolean) {
    Row(
        Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Top + WindowInsetsSides.Horizontal))
            .padding(start = 20.dp, end = 6.dp, top = 8.dp, bottom = 4.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Column(Modifier.weight(1f).padding(top = 4.dp)) {
            Text(
                s.macName.replaceFirstChar { it.uppercase() }, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold,
                maxLines = 2, overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(6.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                StatusDot(connected, animate = animate)
                Spacer(Modifier.width(8.dp))
                Crossfade(if (connected) "Connected" else if (s.lastSeen > 0) "Last seen ${ago(s.lastSeen, now)}" else "Looking for your Mac…", label = "status") {
                    Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        IconButton(onSettings, Modifier.size(48.dp).semantics { contentDescription = "Settings" }) {
            Icon(Glyphs.Gear, null, Modifier.size(26.dp))
        }
    }
}

@Composable
private fun AttentionBanner(items: List<Attention>, onOpen: () -> Unit) {
    val cs = MaterialTheme.colorScheme
    Surface(onClick = onOpen, shape = RoundedCornerShape(22.dp), color = cs.errorContainer, contentColor = cs.onErrorContainer, modifier = Modifier.fillMaxWidth()) {
        Row(Modifier.heightIn(min = 64.dp).padding(start = 16.dp, end = 12.dp, top = 10.dp, bottom = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.Warning, null, Modifier.size(24.dp))
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    if (items.size == 1) "1 thing needs attention" else "${items.size} things need attention",
                    style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold,
                )
                Text(
                    if (items.size == 1) items[0].problem else items.joinToString(", ") { it.name },
                    style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
            }
            Spacer(Modifier.width(10.dp))
            Surface(shape = RoundedCornerShape(50), color = cs.onErrorContainer, contentColor = cs.errorContainer) {
                Text(if (items.size == 1) items[0].action else "Review", Modifier.padding(horizontal = 16.dp, vertical = 8.dp), style = MaterialTheme.typography.labelLarge, maxLines = 1)
            }
        }
    }
}

@Composable
internal fun FixList(items: List<Attention>, onRun: (Attention) -> Unit) {
    Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 24.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text("Needs attention", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(8.dp))
        items.forEach { it ->
            Row(Modifier.fillMaxWidth().heightIn(min = 56.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(it.name, style = MaterialTheme.typography.titleMedium)
                    Text(it.problem, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Spacer(Modifier.width(12.dp))
                FilledTonalButton(onClick = { onRun(it) }) { Text(it.action, maxLines = 1) }
            }
        }
    }
}

// ---------------------------------------------------------------------------------------- send

@Composable
private fun SendCard(s: UiState, a: Actions, connected: Boolean, onText: () -> Unit) {
    val cs = MaterialTheme.colorScheme
    val t = s.transfers
    Card28 {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Send to your Mac", Modifier.padding(start = 4.dp, top = 2.dp), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Row(Modifier.height(IntrinsicSize.Max), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                SendTile(Glyphs.PhotoLibrary, "Photos & videos", cs.primaryContainer, cs.onPrimaryContainer, a.pickMedia, Modifier.weight(1f).fillMaxHeight())
                SendTile(Glyphs.File, "Files", cs.secondaryContainer, cs.onSecondaryContainer, a.pickFiles, Modifier.weight(1f).fillMaxHeight())
            }
            Row(Modifier.height(IntrinsicSize.Max), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                SendTile(Glyphs.Clipboard, "Paste", cs.tertiaryContainer, cs.onTertiaryContainer, a.paste, Modifier.weight(1f).fillMaxHeight())
                SendTile(Glyphs.TextFields, "Text or link", cs.surfaceContainerHighest, cs.onSurface, onText, Modifier.weight(1f).fillMaxHeight())
            }
            AnimatedVisibility(!connected, enter = fadeIn() + expandVertically(), exit = fadeOut() + shrinkVertically()) {
                Row(Modifier.padding(horizontal = 4.dp), verticalAlignment = Alignment.Top) {
                    Icon(Icons.Default.Info, null, Modifier.size(18.dp).padding(top = 1.dp), tint = cs.onSurfaceVariant)
                    Spacer(Modifier.width(8.dp))
                    Text("Sends when your Mac is back", style = MaterialTheme.typography.bodyMedium, color = cs.onSurfaceVariant)
                }
            }
            val rows = t.live.size + t.queued.size
            AnimatedVisibility(rows > 0, enter = fadeIn() + expandVertically(), exit = fadeOut() + shrinkVertically()) {
                Column(Modifier.padding(horizontal = 4.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    t.live.forEach { LiveRow(it) }
                    t.queued.forEach { QueuedRow(it) }
                }
            }
        }
    }
}

@Composable
private fun SendTile(icon: ImageVector, label: String, container: Color, onContainer: Color, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Surface(onClick = onClick, modifier = modifier, shape = RoundedCornerShape(22.dp), color = container, contentColor = onContainer) {
        Column(Modifier.heightIn(min = 96.dp).padding(16.dp), verticalArrangement = Arrangement.SpaceBetween) {
            Icon(icon, null, Modifier.size(28.dp))
            Spacer(Modifier.height(10.dp))
            Text(label, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun LiveRow(t: LiveTransfer) {
    val progress by animateFloatAsState(t.fraction, tween(220, easing = LinearOutSlowInEasing), label = "progress")
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(t.name, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Spacer(Modifier.width(12.dp))
            Text("${(progress * 100).toInt()}%", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
        }
        if (t.total > 0) LinearProgressIndicator(progress = { progress }, Modifier.fillMaxWidth().height(6.dp), strokeCap = androidx.compose.ui.graphics.StrokeCap.Round)
        else LinearProgressIndicator(Modifier.fillMaxWidth().height(6.dp), strokeCap = androidx.compose.ui.graphics.StrokeCap.Round)
        Text(
            if (t.total > 0) "${Transfers.formatSize(t.sent)} of ${Transfers.formatSize(t.total)}" else "Sending…",
            style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun QueuedRow(q: QueuedItem) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(q.name, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text("Waiting for your Mac", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (q.size > 0) {
            Spacer(Modifier.width(12.dp))
            Text(Transfers.formatSize(q.size), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

// ---------------------------------------------------------------------------------------- text sheet

/** Body of the "Text or link" sheet. A single link opens in the Mac's browser; anything else lands on its clipboard. */
@Composable
internal fun SendTextContent(connected: Boolean, macName: String, onSend: (String) -> Unit, initial: String = "", autoFocus: Boolean = false) {
    var text by rememberSaveable { mutableStateOf(initial) }
    val isLink = Links.safe(text) != null
    val focus = remember { FocusRequester() }
    if (autoFocus) LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
    Column(
        Modifier.fillMaxWidth().imePadding().navigationBarsPadding().padding(horizontal = 20.dp).padding(bottom = 20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Text("Text or link", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
        OutlinedTextField(
            value = text, onValueChange = { text = it },
            modifier = Modifier.fillMaxWidth().focusRequester(focus),
            placeholder = { Text("Text or link") },
            minLines = 3, maxLines = 6, shape = RoundedCornerShape(18.dp),
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
        )
        if (text.isNotBlank()) Text(
            if (isLink) "Opens in your Mac's browser" else "Copies to your Mac's clipboard",
            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Button(
            onClick = { onSend(text) }, enabled = text.isNotBlank(),
            modifier = Modifier.fillMaxWidth().height(56.dp), shape = RoundedCornerShape(18.dp),
        ) {
            Icon(Glyphs.Send, null, Modifier.size(20.dp))
            Spacer(Modifier.width(10.dp))
            Text(if (connected) "Send to ${macName.replaceFirstChar { it.uppercase() }}" else "Send when connected", maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

// ---------------------------------------------------------------------------------------- your mac

// ---------------------------------------------------------------------------------------- activity

private fun startOfToday(now: Long): Long = Calendar.getInstance().apply {
    timeInMillis = now
    set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
}.timeInMillis

@Composable
private fun ActivityCard(s: UiState, now: Long, onSend: () -> Unit) {
    val cs = MaterialTheme.colorScheme
    val t = s.transfers
    val photosOn = s.settings?.photos == true
    val today = t.photosSince(startOfToday(now))
    val showPhotos = photosOn && (today > 0 || s.photosWaiting > 0)
    val recent = t.recent.take(8)
    Card28 {
        Column(Modifier.padding(vertical = 8.dp).animateContentSize()) {
            if (showPhotos) {
                ActivityLine(
                    Glyphs.PhotoLibrary, cs.primaryContainer, cs.onPrimaryContainer,
                    title = if (today > 0) "${plural(today, "photo", "photos")} synced today" else "No photos synced today",
                    sub = if (s.photosWaiting > 0) "${s.photosWaiting} waiting to sync" else "Up to date",
                )
            }
            recent.forEach { e -> ActivityEntryRow(e, now) }
            if (!showPhotos && recent.isEmpty()) {
                Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 28.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    IconBadge(Glyphs.ArrowUp, cs.surfaceContainerHighest, cs.onSurfaceVariant)
                    Spacer(Modifier.height(12.dp))
                    Text("No activity yet", style = MaterialTheme.typography.titleMedium)
                    Spacer(Modifier.height(2.dp))
                    Text(
                        "Sent and received items show here",
                        style = MaterialTheme.typography.bodyMedium, color = cs.onSurfaceVariant, textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    )
                    Spacer(Modifier.height(16.dp))
                    Button(onSend) { Text("Send a file") }
                }
            }
        }
    }
}

@Composable
private fun ActivityEntryRow(e: ActivityEntry, now: Long) {
    val cs = MaterialTheme.colorScheme
    val icon = when (e.kind) {
        Kind.Text -> Glyphs.TextFields
        Kind.Link -> Glyphs.Link
        Kind.File -> if (e.dir == Direction.ToMac) Glyphs.ArrowUp else Glyphs.ArrowDown
        Kind.Auth -> Glyphs.Key
    }
    val (container, tint) = when {
        !e.ok -> cs.errorContainer to cs.onErrorContainer
        e.dir == Direction.FromMac -> cs.tertiaryContainer to cs.onTertiaryContainer
        else -> cs.secondaryContainer to cs.onSecondaryContainer
    }
    val status = when {
        !e.ok -> "Not sent"
        e.dir == Direction.FromMac -> "From your Mac"
        else -> "Sent"
    }
    ActivityLine(icon, container, tint, title = e.title, sub = listOfNotNull(status, ago(e.at, now), e.detail).joinToString(" · "), subColor = if (e.ok) null else cs.error)
}

@Composable
private fun ActivityLine(icon: ImageVector, container: Color, tint: Color, title: String, sub: String, subColor: Color? = null) {
    Row(Modifier.fillMaxWidth().heightIn(min = 64.dp).padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        IconBadge(icon, container, tint)
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(sub, style = MaterialTheme.typography.bodySmall, color = subColor ?: MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
    }
}

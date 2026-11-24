package com.mydroid.android.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mydroid.android.mac.MacUi
import com.mydroid.protocol.MacStatus

/** What the Your Mac card can ask the app to do. Defaults make it renderable on its own. */
class MacActions(
    val lock: () -> Unit = {},
    val sleep: () -> Unit = {},
    val ring: () -> Unit = {},
    val loadShortcuts: () -> Unit = {},
    val runShortcut: (String) -> Unit = {},
    val toggleFavorite: (String) -> Unit = {},
)

// ---------------------------------------------------------------------------------------- card

/** Status, quick actions, starred Shortcuts, Remote and Mac files. Actions need a live connection and say so when there isn't one. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun MacCard(
    mac: MacUi, connected: Boolean, a: MacActions, onShortcuts: () -> Unit, onRemote: () -> Unit, onFiles: () -> Unit,
    auth: com.mydroid.android.auth.AuthUi = com.mydroid.android.auth.AuthUi(), onAuth: () -> Unit = {},
) {
    val cs = MaterialTheme.colorScheme
    Card28 {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (!connected || mac.status != null) MacStatusLine(mac.status, connected)
            Row(Modifier.height(IntrinsicSize.Max), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                QuickAction(Glyphs.Lock, "Lock", cs.secondaryContainer, cs.onSecondaryContainer, connected, a.lock, Modifier.weight(1f).fillMaxHeight())
                QuickAction(Glyphs.Moon, "Sleep", cs.secondaryContainer, cs.onSecondaryContainer, connected, a.sleep, Modifier.weight(1f).fillMaxHeight())
                if (mac.ringing) QuickAction(Glyphs.Bell, "Stop", cs.primary, cs.onPrimary, connected, a.ring, Modifier.weight(1f).fillMaxHeight(), description = "Stop ringing your Mac")
                else QuickAction(Glyphs.Bell, "Ring", cs.tertiaryContainer, cs.onTertiaryContainer, connected, a.ring, Modifier.weight(1f).fillMaxHeight(), description = "Ring your Mac")
                QuickAction(Glyphs.Bolt, "Shortcuts", cs.surfaceContainerHighest, cs.onSurface, connected, onShortcuts, Modifier.weight(1f).fillMaxHeight())
            }
            if (mac.favorites.isNotEmpty()) {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    mac.favorites.forEach { name -> ShortcutChip(name, connected) { a.runShortcut(name) } }
                }
            }
        }
        HorizontalDivider(Modifier.padding(horizontal = 16.dp), color = cs.outlineVariant.copy(alpha = 0.5f))
        MacRow(Glyphs.Mouse, "Remote", "Pad, slides, music, apps", cs.primaryContainer, cs.onPrimaryContainer, onRemote)
        HorizontalDivider(Modifier.padding(start = 70.dp, end = 16.dp), color = cs.outlineVariant.copy(alpha = 0.5f))
        MacRow(Glyphs.Folder, "Mac files", "Opens in Files", cs.secondaryContainer, cs.onSecondaryContainer, onFiles)
        HorizontalDivider(Modifier.padding(start = 70.dp, end = 16.dp), color = cs.outlineVariant.copy(alpha = 0.5f))
        MacRow(
            Glyphs.Key, "Authenticator",
            when {
                auth.unreadable -> "Can't open accounts"
                auth.count == 0 -> "Two-factor codes"
                auth.nudge -> "${plural(auth.count, "account", "accounts")} · Not backed up"
                else -> plural(auth.count, "account", "accounts")
            },
            cs.tertiaryContainer, cs.onTertiaryContainer, onAuth,
        )
    }
}

@Composable
private fun MacStatusLine(status: MacStatus?, connected: Boolean) {
    val cs = MaterialTheme.colorScheme
    Row(Modifier.fillMaxWidth().heightIn(min = 28.dp).padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        when {
            !connected -> Text("Your Mac is away", style = MaterialTheme.typography.bodyMedium, color = cs.onSurfaceVariant)
            status == null -> Text("Connected", style = MaterialTheme.typography.bodyMedium, color = cs.onSurfaceVariant)
            else -> {
                status.batteryText?.let {
                    androidx.compose.material3.Icon(Glyphs.Battery, null, Modifier.size(18.dp), tint = cs.onSurfaceVariant)
                    Spacer(Modifier.width(6.dp))
                    Text(it, style = MaterialTheme.typography.bodyMedium, color = cs.onSurfaceVariant)
                    Spacer(Modifier.width(10.dp))
                }
                val (label, container, tint) = when (status.presence) {
                    MacStatus.Presence.Locked -> Triple("Locked", cs.secondaryContainer, cs.onSecondaryContainer)
                    MacStatus.Presence.Asleep -> Triple("Display asleep", cs.surfaceContainerHighest, cs.onSurfaceVariant)
                    MacStatus.Presence.Awake -> Triple("Awake", cs.primaryContainer, cs.onPrimaryContainer)
                }
                Surface(shape = RoundedCornerShape(50), color = container, contentColor = tint) {
                    Text(label, Modifier.padding(horizontal = 10.dp, vertical = 3.dp), style = MaterialTheme.typography.labelMedium, maxLines = 1)
                }
            }
        }
    }
}

@Composable
private fun QuickAction(
    icon: ImageVector, label: String, container: Color, onContainer: Color, enabled: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier,
    description: String = label,
) {
    Surface(
        onClick = onClick, enabled = enabled,
        modifier = modifier.alpha(if (enabled) 1f else 0.45f).semantics { contentDescription = description },
        shape = RoundedCornerShape(20.dp), color = container, contentColor = onContainer,
    ) {
        Column(
            Modifier.heightIn(min = 80.dp).padding(horizontal = 2.dp, vertical = 12.dp).fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
        ) {
            Icon(icon, null, Modifier.size(26.dp))
            Spacer(Modifier.height(6.dp))
            Text(label, style = MaterialTheme.typography.labelMedium.copy(fontSize = 12.sp), fontWeight = FontWeight.SemiBold, maxLines = 1, softWrap = false)
        }
    }
}

@Composable
private fun ShortcutChip(name: String, enabled: Boolean, onClick: () -> Unit) {
    val cs = MaterialTheme.colorScheme
    Surface(
        onClick = onClick, enabled = enabled, shape = RoundedCornerShape(50), color = cs.surfaceContainerHighest, contentColor = cs.onSurface,
        modifier = Modifier.alpha(if (enabled) 1f else 0.45f).semantics { contentDescription = "Run $name" },
    ) {
        Row(Modifier.heightIn(min = 44.dp).padding(start = 12.dp, end = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Glyphs.Bolt, null, Modifier.size(18.dp), tint = cs.primary)
            Spacer(Modifier.width(8.dp))
            Text(name, style = MaterialTheme.typography.labelLarge, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 180.dp))
        }
    }
}

@Composable
private fun MacRow(icon: ImageVector, title: String, sub: String, container: Color, tint: Color, onClick: () -> Unit) {
    val cs = MaterialTheme.colorScheme
    Surface(onClick = onClick, Modifier.fillMaxWidth(), color = Color.Transparent) {
        Row(Modifier.heightIn(min = 72.dp).padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            IconBadge(icon, container, tint)
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.titleMedium)
                Text(sub, style = MaterialTheme.typography.bodyMedium, color = cs.onSurfaceVariant)
            }
            Icon(Glyphs.ChevronRight, null, tint = cs.onSurfaceVariant)
        }
    }
}

// ---------------------------------------------------------------------------------------- shortcuts sheet

/** Body of the Shortcuts sheet: the Mac's Shortcuts, with a star on each to pin it to the card. */
@Composable
internal fun ShortcutsContent(mac: MacUi, onRun: (String) -> Unit, onStar: (String) -> Unit, onRetry: () -> Unit) {
    val cs = MaterialTheme.colorScheme
    val loaded = mac.shortcuts
    // Starred first, then the rest, both alphabetical.
    val sorted = loaded?.sortedWith(compareBy({ it !in mac.favorites }, { it.lowercase() }))
    Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(bottom = 16.dp)) {
        Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("Shortcuts", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Text("Star to keep on Home", style = MaterialTheme.typography.bodyMedium, color = cs.onSurfaceVariant)
        }
        Spacer(Modifier.height(8.dp))
        when {
            mac.shortcutsLoading && loaded == null -> Box(Modifier.fillMaxWidth().height(160.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            mac.shortcutsError != null && loaded == null -> Column(
                Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Text(mac.shortcutsError, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
                Button(onClick = onRetry, Modifier.heightIn(min = 48.dp)) { Text("Try again") }
            }
            sorted != null && sorted.isEmpty() -> Column(
                Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text("No shortcuts yet", style = MaterialTheme.typography.titleMedium)
                Text("Create one in Shortcuts on your Mac", style = MaterialTheme.typography.bodyMedium, color = cs.onSurfaceVariant, textAlign = TextAlign.Center)
                Spacer(Modifier.height(8.dp))
                Button(onClick = onRetry, Modifier.heightIn(min = 48.dp)) { Text("Refresh") }
            }
            sorted != null -> LazyColumn(Modifier.heightIn(max = 480.dp)) {
                items(sorted, key = { it }) { name ->
                    val starred = name in mac.favorites
                    Row(Modifier.fillMaxWidth().heightIn(min = 60.dp).padding(start = 20.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Surface(onClick = { onRun(name) }, Modifier.weight(1f).heightIn(min = 56.dp), color = Color.Transparent) {
                            Row(Modifier.fillMaxHeight(), verticalAlignment = Alignment.CenterVertically) {
                                IconBadge(Glyphs.Bolt, cs.secondaryContainer, cs.onSecondaryContainer)
                                Spacer(Modifier.width(14.dp))
                                Text(name, style = MaterialTheme.typography.bodyLarge, maxLines = 2, overflow = TextOverflow.Ellipsis)
                            }
                        }
                        IconButton(onClick = { onStar(name) }, Modifier.size(52.dp).semantics { contentDescription = if (starred) "Remove $name from Home" else "Keep $name on Home" }) {
                            Icon(if (starred) Glyphs.Star else Glyphs.StarOutline, null, tint = if (starred) cs.primary else cs.onSurfaceVariant)
                        }
                    }
                }
            }
        }
    }
}

package com.mydroid.android.ui

import android.text.format.DateUtils
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/** "just now", "5 min. ago", "2 hr. ago". */
internal fun ago(at: Long, now: Long): String =
    if (now - at < 60_000) "just now"
    else DateUtils.getRelativeTimeSpanString(at, now, DateUtils.MINUTE_IN_MILLIS, DateUtils.FORMAT_ABBREV_RELATIVE).toString()

internal fun plural(n: Int, one: String, many: String) = if (n == 1) "1 $one" else "$n $many"

/** Rounded surface used for every card on Home and Settings. */
@Composable
internal fun Card28(modifier: Modifier = Modifier, color: Color = MaterialTheme.colorScheme.surfaceContainerLow, content: @Composable ColumnScope.() -> Unit) {
    Surface(modifier.fillMaxWidth(), shape = RoundedCornerShape(28.dp), color = color) { Column(content = content) }
}

@Composable
internal fun SectionLabel(text: String, modifier: Modifier = Modifier) {
    Text(
        text, modifier.padding(start = 8.dp, top = 4.dp), style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.primary,
    )
}

/** A round tinted icon, 40 dp. */
@Composable
internal fun IconBadge(icon: ImageVector, container: Color, tint: Color, modifier: Modifier = Modifier) {
    Box(modifier.size(40.dp).clip(CircleShape).background(container), contentAlignment = Alignment.Center) {
        Icon(icon, null, Modifier.size(22.dp), tint = tint)
    }
}

/** Solid when connected, pulsing while we look for the Mac. */
@Composable
internal fun StatusDot(on: Boolean, modifier: Modifier = Modifier, animate: Boolean = true) {
    val color by animateColorAsState(if (on) Color(0xFF34C759) else MaterialTheme.colorScheme.outline, label = "dotColor")
    val pulse = if (on || !animate) 1f else {
        val t = rememberInfiniteTransition(label = "dot")
        t.animateFloat(0.35f, 1f, infiniteRepeatable(tween(900), RepeatMode.Reverse), label = "a").value
    }
    Box(modifier.size(10.dp).alpha(pulse).clip(CircleShape).background(color))
}

/** The detail behind an ⓘ: a title and at most three short sentences. */
internal class Info(val title: String, val body: String)

/** Small ⓘ button. The 48 dp touch target is Material's default; the icon stays quiet. */
@Composable
internal fun InfoButton(info: Info, modifier: Modifier = Modifier) {
    var open by rememberSaveable(info.title) { mutableStateOf(false) }
    IconButton({ open = true }, modifier.semantics { contentDescription = "About ${info.title}" }) {
        Icon(Icons.Default.Info, null, Modifier.size(20.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    if (open) InfoSheet(info) { open = false }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun InfoSheet(info: Info, onDismiss: () -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss) { InfoSheetContent(info) }
}

@Composable
internal fun InfoSheetContent(info: Info) {
    Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 24.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(info.title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
        Text(info.body, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

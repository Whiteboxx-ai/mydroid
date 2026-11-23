package com.mydroid.android.ui

import android.graphics.BitmapFactory
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import com.mydroid.android.net.Link
import com.mydroid.android.net.UiState
import com.mydroid.android.remote.RemoteApi
import com.mydroid.protocol.FsHit
import com.mydroid.protocol.MacApp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

private enum class FileFilter(val label: String, val exts: Set<String>?) {
    All("All", null),
    Slides("Slides", setOf("key", "pptx", "ppt", "ppsx", "pps", "odp")),
    Documents("Documents", setOf("pdf", "doc", "docx", "pages", "txt", "rtf", "md", "xls", "xlsx", "numbers", "csv")),
    Images("Images", setOf("png", "jpg", "jpeg", "heic", "gif", "webp", "tiff"));

    fun accepts(name: String) = exts == null || name.substringAfterLast('.', "").lowercase() in exts
}

/** Open: one search for apps and files on the Mac, the apps that are running, and recent files. Everything opens on the Mac. */
@Composable
internal fun OpenPane(s: UiState, api: RemoteApi, insets: Modifier, previewFiles: List<FsHit>? = null) {
    val cs = MaterialTheme.colorScheme
    val connected = s.link == Link.Connected
    LaunchedEffect(connected) { if (connected) api.loadApps() }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { if (connected) api.loadApps() }

    var query by rememberSaveable { mutableStateOf("") }
    var filter by rememberSaveable { mutableStateOf(FileFilter.All.name) }
    var files by remember { mutableStateOf(previewFiles) }
    var loading by remember { mutableStateOf(false) }
    LaunchedEffect(query, connected) {
        if (previewFiles != null || !connected) return@LaunchedEffect
        if (query.isNotBlank()) delay(300)   // wait for the typing to settle
        loading = true
        files = withContext(Dispatchers.IO) { api.findFiles(query) }?.filter { !it.entry.dir }
        loading = false
    }

    val apps = s.mac.apps
    val q = query.trim()
    val appMatches = if (q.isEmpty()) emptyList() else
        ((apps?.running.orEmpty()) + (apps?.installed.orEmpty())).distinctBy { it.id }.filter { it.name.contains(q, ignoreCase = true) }.take(8)
    val active = FileFilter.valueOf(filter)
    val shown = files?.filter { active.accepts(it.entry.name) }

    LazyColumn(Modifier.fillMaxSize().then(insets), contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item {
            val focus = androidx.compose.ui.platform.LocalFocusManager.current
            OutlinedTextField(
                query, { query = it }, Modifier.fillMaxWidth().semantics { contentDescription = "Search apps and files on your Mac" },
                singleLine = true, shape = RoundedCornerShape(28.dp), placeholder = { Text("Search apps and files on your Mac") },
                leadingIcon = { Icon(Glyphs.Search, null) },
                trailingIcon = { if (query.isNotEmpty()) IconButton({ query = "" }) { Icon(Glyphs.Close, "Clear") } },
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search), keyboardActions = KeyboardActions(onSearch = { focus.clearFocus() }),
            )
        }

        if (q.isEmpty()) {
            val running = apps?.running.orEmpty()
            if (running.isNotEmpty()) {
                item { Spacer(Modifier.height(6.dp)); SectionLabel("Open now") }
                item {
                    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        running.forEach { a -> RunningApp(a) { api.launchApp(a) } }
                    }
                }
            } else if (apps?.loading == true) {
                item { Box(Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 3.dp) } }
            }
            item {
                Spacer(Modifier.height(6.dp)); SectionLabel("Recent files")
                Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FileFilter.entries.forEach { f -> FilterChip(f == active, { filter = f.name }, { Text(f.label) }, shape = RoundedCornerShape(12.dp)) }
                }
            }
        } else if (appMatches.isNotEmpty()) {
            item { Spacer(Modifier.height(6.dp)); SectionLabel("Apps") }
            items(appMatches, key = { "app:" + it.id }) { a -> AppRow(a) { api.launchApp(a) } }
            item { Spacer(Modifier.height(6.dp)); SectionLabel("Files") }
        }

        when {
            shown == null && loading -> item { Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(Modifier.size(28.dp), strokeWidth = 3.dp) } }
            shown == null -> item { Hint(if (connected) "Couldn't read your Mac's files. Turn on file sharing in Mydroid for Mac." else "Your Mac isn't connected.") }
            shown.isEmpty() -> item { Hint(if (q.isEmpty()) "No recent files in the folders you share." else "Nothing found for “$q”.") }
            else -> items(shown, key = { "file:" + it.root + "/" + it.path }) { h -> FileRow(h) { api.openFile(h) } }
        }
    }
}

@Composable
private fun Hint(text: String) {
    Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth().padding(24.dp))
}

@Composable
private fun RunningApp(a: MacApp, onClick: () -> Unit) {
    Column(
        Modifier.width(72.dp).clip(RoundedCornerShape(16.dp)).clickable(onClickLabel = "Open ${a.name}", onClick = onClick).padding(vertical = 4.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        AppIcon(a, Modifier.size(60.dp))
        Text(a.name, style = MaterialTheme.typography.labelMedium, maxLines = 1, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center)
    }
}

@Composable
private fun AppRow(a: MacApp, onClick: () -> Unit) {
    val cs = MaterialTheme.colorScheme
    Surface(onClick, shape = RoundedCornerShape(20.dp), color = cs.surfaceContainerLow) {
        Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            AppIcon(a, Modifier.size(44.dp))
            Text(a.name, Modifier.weight(1f), style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
            FilledTonalButton(onClick, contentPadding = PaddingValues(horizontal = 16.dp)) { Text("Open") }
        }
    }
}

@Composable
private fun FileRow(h: FsHit, onOpen: () -> Unit) {
    val cs = MaterialTheme.colorScheme
    Surface(onOpen, shape = RoundedCornerShape(20.dp), color = cs.surfaceContainerLow) {
        Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            FileTile(h.entry.name, Modifier.size(42.dp))
            Column(Modifier.weight(1f)) {
                Text(h.entry.name, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(listOf(h.path.substringBeforeLast('/', "").ifEmpty { "Top level" }, relativeDay(h.entry.mtime)).filter { it.isNotEmpty() }.joinToString(" · "),
                    style = MaterialTheme.typography.bodySmall, color = cs.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            FilledTonalButton(onOpen, contentPadding = PaddingValues(horizontal = 16.dp)) { Text("Open") }
        }
    }
}

/** The app's own icon when the Mac sent one (running apps), else its first letter on a tinted tile. */
@Composable
internal fun AppIcon(a: MacApp, modifier: Modifier) {
    val bmp = remember(a.id, a.icon?.size) { a.icon?.let { runCatching { BitmapFactory.decodeByteArray(it, 0, it.size) }.getOrNull() }?.asImageBitmap() }
    if (bmp != null) {
        Image(bmp, null, modifier)
    } else {
        val cs = MaterialTheme.colorScheme
        val tints = listOf(cs.primaryContainer to cs.onPrimaryContainer, cs.secondaryContainer to cs.onSecondaryContainer, cs.tertiaryContainer to cs.onTertiaryContainer)
        val (bg, fg) = tints[(a.id.hashCode() and 0x7fffffff) % tints.size]
        Box(modifier.clip(RoundedCornerShape(14.dp)).background(bg), contentAlignment = Alignment.Center) {
            Text(a.name.take(1).uppercase(), color = fg, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        }
    }
}

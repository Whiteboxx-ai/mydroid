package com.mydroid.android.ui

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import androidx.compose.animation.*
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.SecureFlagPolicy
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.mydroid.android.auth.*
import com.mydroid.android.net.UiState
import com.mydroid.protocol.auth.*
import kotlinx.coroutines.delay

private enum class AuthPage { List, Manual, Edit }

private val listInfo = Info("Using codes", "Tap a code to copy it. Press and hold to edit. Codes go to your Mac only after you approve.")

internal fun Context.findActivity(): Activity? {
    var c: Context? = this
    while (c is ContextWrapper) { if (c is Activity) return c; c = c.baseContext }
    return null
}

/** Wall clock in ms, ticking 4 times a second while the screen is showing; nothing runs when the app is stopped. */
@Composable
private fun rememberTicker(): Long {
    var t by remember { mutableLongStateOf(System.currentTimeMillis()) }
    val owner = LocalLifecycleOwner.current
    LaunchedEffect(owner) {
        owner.lifecycle.repeatOnLifecycle(androidx.lifecycle.Lifecycle.State.STARTED) { while (true) { t = System.currentTimeMillis(); delay(250) } }
    }
    return t
}

// ---------------------------------------------------------------------------------------- screen

/** The Authenticator: gate, list, adding and editing. Codes are on screen here, so the window is kept out of screenshots and Recents. */
@Composable
internal fun AuthenticatorScreen(s: UiState, api: AuthApi, onBack: () -> Unit) {
    val entries by api.entries.collectAsState()
    val open by api.gateOpen.collectAsState()
    val progress by api.importProgress.collectAsState()
    val nowMs = rememberTicker()
    DisposableEffect(Unit) { api.secure(true); onDispose { api.secure(false) } }
    val unlocked = open || !s.auth.requireBiometric
    LaunchedEffect(unlocked) { if (!unlocked) api.unlock() }
    AuthenticatorContent(s, entries, nowMs, unlocked, progress, api, onBack)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun AuthenticatorContent(
    s: UiState, entries: List<AuthEntry>, nowMs: Long, unlocked: Boolean, progress: ImportProgress?, api: AuthApi, onBack: () -> Unit,
    initialAddSheet: Boolean = false,
) {
    var page by rememberSaveable { mutableStateOf(AuthPage.List) }
    var editId by rememberSaveable { mutableStateOf<String?>(null) }
    var showAdd by rememberSaveable { mutableStateOf(initialAddSheet) }
    androidx.activity.compose.BackHandler(enabled = page != AuthPage.List) { page = AuthPage.List }

    Column(Modifier.fillMaxSize()) {
        when (page) {
            AuthPage.Manual -> ManualPage(api, onClose = { page = AuthPage.List })
            AuthPage.Edit -> {
                val e = entries.firstOrNull { it.id == editId }
                if (e == null) page = AuthPage.List else EditPage(e, api, onClose = { page = AuthPage.List })
            }
            AuthPage.List -> {
                AuthHeader(onBack, onAdd = if (unlocked) ({ showAdd = true }) else null, info = if (unlocked && entries.isNotEmpty()) listInfo else null)
                when {
                    s.auth.unreadable -> Unreadable(api)
                    !unlocked -> Locked(onUnlock = api::unlock)
                    entries.isEmpty() && progress == null -> EmptyAccounts(
                        onScan = api::scan, onImport = api::scan, onManual = { page = AuthPage.Manual }, onRestore = api::beginRestore,
                    )
                    else -> AccountList(
                        s, entries, nowMs, progress, api, onEdit = { editId = it; page = AuthPage.Edit },
                    )
                }
            }
        }
    }
    if (showAdd) {
        ModalBottomSheet(onDismissRequest = { showAdd = false }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
            AddSheetContent(
                onScan = { showAdd = false; api.scan() }, onImport = { showAdd = false; api.scan() },
                onManual = { showAdd = false; page = AuthPage.Manual }, onRestore = { showAdd = false; api.beginRestore() },
            )
        }
    }
}

@Composable
private fun AuthHeader(onBack: () -> Unit, onAdd: (() -> Unit)?, info: Info? = null) {
    Row(
        Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Top + WindowInsetsSides.Horizontal)).padding(start = 6.dp, end = 16.dp, top = 8.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onBack, Modifier.size(48.dp).semantics { contentDescription = "Back" }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, null) }
        Spacer(Modifier.width(6.dp))
        Text("Authenticator", Modifier.weight(1f), style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        if (info != null) InfoButton(info)
        if (onAdd != null) FilledTonalIconButton(onAdd, Modifier.size(48.dp).semantics { contentDescription = "Add account" }) { Icon(Icons.Default.Add, null) }
    }
}

// ---------------------------------------------------------------------------------------- list

@Composable
private fun AccountList(s: UiState, entries: List<AuthEntry>, nowMs: Long, progress: ImportProgress?, api: AuthApi, onEdit: (String) -> Unit) {
    val cs = MaterialTheme.colorScheme
    LazyColumn(
        Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom)),
        contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 12.dp, bottom = 28.dp), verticalArrangement = Arrangement.spacedBy(0.dp),
    ) {
        if (progress != null) item { ImportCard(progress, onNext = api::scanNextPart, onCancel = api::cancelImport); Spacer(Modifier.height(16.dp)) }
        if (s.auth.nudge) item { BackupNudge(onBackup = api::beginBackup, onDismiss = api::dismissNudge); Spacer(Modifier.height(16.dp)) }
        itemsIndexed(entries, key = { _, e -> e.id }) { i, e ->
            val shape = when {
                entries.size == 1 -> RoundedCornerShape(28.dp)
                i == 0 -> RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)
                i == entries.lastIndex -> RoundedCornerShape(bottomStart = 28.dp, bottomEnd = 28.dp)
                else -> RoundedCornerShape(0.dp)
            }
            Surface(Modifier.fillMaxWidth(), shape = shape, color = cs.surfaceContainerLow) {
                Column {
                    if (i > 0) HorizontalDivider(Modifier.padding(start = 76.dp, end = 16.dp), color = cs.outlineVariant.copy(alpha = 0.5f))
                    AccountRow(e, nowMs, onCopy = { api.copyCode(e) }, onEdit = { onEdit(e.id) }, onNext = { api.nextHotp(e.id) })
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun AccountRow(e: AuthEntry, nowMs: Long, onCopy: () -> Unit, onEdit: () -> Unit, onNext: () -> Unit) {
    val cs = MaterialTheme.colorScheme
    val secs = nowMs / 1000
    val code = e.code(secs)
    val left = Otp.secondsRemaining(secs, e.period)
    val low = e.type == OtpType.TOTP && left <= 5
    val shown = code?.let { groupCode(it) } ?: "Invalid key"
    Row(
        Modifier.fillMaxWidth().heightIn(min = 80.dp)
            .combinedClickable(onClickLabel = "Copy code", onLongClickLabel = "Edit account", onClick = onCopy, onLongClick = onEdit)
            .semantics(mergeDescendants = true) { contentDescription = "${e.title}${if (e.account.isNotBlank()) ", ${e.account}" else ""}. Code ${code?.toList()?.joinToString(" ") ?: "unavailable"}" }
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Avatar(e.issuer.ifBlank { e.account })
        Spacer(Modifier.width(16.dp))
        Column(Modifier.weight(1f)) {
            Text(e.title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis, color = cs.onSurface)
            if (e.account.isNotBlank() && e.issuer.isNotBlank()) Text(e.account, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis, color = cs.onSurfaceVariant)
            Text(
                shown, Modifier.padding(top = 2.dp), color = if (low) cs.error else cs.primary, maxLines = 1,
                style = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.Medium, fontFeatureSettings = "tnum", letterSpacing = 1.sp),
            )
        }
        Spacer(Modifier.width(8.dp))
        if (e.type == OtpType.TOTP) CountdownRing(Otp.fractionRemaining(nowMs, e.period), left, low)
        else IconButton(onNext, Modifier.size(48.dp).semantics { contentDescription = "Next code" }) { Icon(Icons.Default.Refresh, null, tint = cs.primary) }
    }
}

internal fun groupCode(c: String) = when (c.length) { 6 -> "${c.substring(0, 3)} ${c.substring(3)}"; 8 -> "${c.substring(0, 4)} ${c.substring(4)}"; else -> c }

@Composable
internal fun CountdownRing(fraction: Float, secondsLeft: Int, low: Boolean) {
    val cs = MaterialTheme.colorScheme
    Box(Modifier.size(44.dp), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(
            progress = { fraction.coerceIn(0f, 1f) }, modifier = Modifier.fillMaxSize(), strokeWidth = 3.5.dp,
            color = if (low) cs.error else cs.primary, trackColor = cs.surfaceContainerHighest, strokeCap = androidx.compose.ui.graphics.StrokeCap.Round,
            gapSize = 0.dp,
        )
        Text("$secondsLeft", style = MaterialTheme.typography.labelMedium.copy(fontFeatureSettings = "tnum"), color = if (low) cs.error else cs.onSurfaceVariant)
    }
}

/** Initials on a tint picked from the name, so the same service always looks the same. */
@Composable
internal fun Avatar(name: String, size: Int = 44) {
    val dark = MaterialTheme.colorScheme.background.luminance() < 0.5f
    val hue = ((name.lowercase().hashCode() and 0x7FFFFFFF) % 360).toFloat()
    val bg = Color.hsl(hue, 0.42f, if (dark) 0.26f else 0.86f)
    val fg = Color.hsl(hue, 0.5f, if (dark) 0.86f else 0.24f)
    val initials = name.trim().split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() }.let { w ->
        when { w.isEmpty() -> "?"; w.size == 1 -> w[0].take(1); else -> w[0].take(1) + w[1].take(1) }
    }.uppercase()
    Box(Modifier.size(size.dp).clip(CircleShape).background(bg), contentAlignment = Alignment.Center) {
        Text(initials, color = fg, fontWeight = FontWeight.SemiBold, fontSize = (size * 0.36f).sp, maxLines = 1)
    }
}

// ---------------------------------------------------------------------------------------- empty, locked, errors

@Composable
internal fun EmptyAccounts(onScan: () -> Unit, onImport: () -> Unit, onManual: () -> Unit, onRestore: () -> Unit) {
    val cs = MaterialTheme.colorScheme
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom))
            .padding(horizontal = 20.dp).padding(top = 12.dp, bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Column(Modifier.fillMaxWidth().padding(top = 12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Box(Modifier.size(72.dp).clip(CircleShape).background(cs.primaryContainer), contentAlignment = Alignment.Center) {
                Icon(Glyphs.Key, null, Modifier.size(34.dp), tint = cs.onPrimaryContainer)
            }
            Spacer(Modifier.height(16.dp))
            Text("Add your first account", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
            Spacer(Modifier.height(6.dp))
            Text("Codes stay encrypted on this phone", style = MaterialTheme.typography.bodyMedium, color = cs.onSurfaceVariant, textAlign = TextAlign.Center)
        }
        Card28 {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(onScan, Modifier.fillMaxWidth().height(56.dp), shape = RoundedCornerShape(18.dp)) {
                    Icon(Glyphs.QrScan, null, Modifier.size(22.dp)); Spacer(Modifier.width(10.dp)); Text("Scan QR code")
                }
                FilledTonalButton(onManual, Modifier.fillMaxWidth().height(56.dp), shape = RoundedCornerShape(18.dp)) { Text("Enter setup key") }
            }
        }
        var showImport by rememberSaveable { mutableStateOf(false) }
        Card28 {
            Column(Modifier.animateContentSize()) {
                Surface(onClick = { showImport = !showImport }, color = Color.Transparent) {
                    Row(Modifier.fillMaxWidth().heightIn(min = 64.dp).padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                        IconBadge(Glyphs.Key, cs.secondaryContainer, cs.onSecondaryContainer)
                        Spacer(Modifier.width(14.dp))
                        Text("Import from Google Authenticator", Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
                        Icon(if (showImport) Icons.Default.KeyboardArrowUp else Icons.Default.KeyboardArrowDown, null, tint = cs.onSurfaceVariant)
                    }
                }
                if (showImport) Column(Modifier.padding(start = 16.dp, end = 16.dp, bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) { ImportPaths(onScanOther = onImport) }
            }
        }
        TextButton(onRestore, Modifier.align(Alignment.CenterHorizontally)) { Text("Restore from backup") }
    }
}

/**
 * Google Authenticator hides its export code from screen capture, so a phone can't scan its own export.
 * Two ways round that: the Mac's camera, or another device's screen.
 */
@Composable
internal fun ImportPaths(onScanOther: () -> Unit, tonal: Boolean = false) {
    val cs = MaterialTheme.colorScheme
    Text("In Google Authenticator: ⋮ › Transfer accounts › Export", style = MaterialTheme.typography.bodyMedium, color = cs.onSurfaceVariant)
    ImportPath("1", "Use your Mac's camera", "Mac: Settings › Authenticator › Import")
    ImportPath("2", "Scan another device's screen", "Show the export code there")
    if (tonal) FilledTonalButton(onScanOther, Modifier.heightIn(min = 48.dp)) { Text("Scan from another device") }
    else OutlinedButton(onScanOther, Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text("Scan from another device") }
}

@Composable
private fun ImportPath(n: String, title: String, body: String) {
    val cs = MaterialTheme.colorScheme
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(24.dp).clip(CircleShape).background(cs.secondaryContainer), contentAlignment = Alignment.Center) {
            Text(n, style = MaterialTheme.typography.labelMedium, color = cs.onSecondaryContainer)
        }
        Spacer(Modifier.width(12.dp))
        Column {
            Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
            Text(body, style = MaterialTheme.typography.bodyMedium, color = cs.onSurfaceVariant)
        }
    }
}

@Composable
internal fun AddSheetContent(onScan: () -> Unit, onImport: () -> Unit, onManual: () -> Unit, onRestore: () -> Unit, initialExpanded: Boolean = false) {
    val cs = MaterialTheme.colorScheme
    var showSteps by remember { mutableStateOf(initialExpanded) }
    Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 20.dp).padding(bottom = 20.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("Add an account", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(6.dp))
        SheetRow(Glyphs.QrScan, "Scan QR code", "From a website's setup page", cs.primaryContainer, cs.onPrimaryContainer, onScan)
        SheetRow(Glyphs.Key, "Import from Google Authenticator", "Mac camera or another device", cs.secondaryContainer, cs.onSecondaryContainer) { showSteps = !showSteps }
        AnimatedVisibility(showSteps) {
            Column(Modifier.padding(start = 54.dp, bottom = 6.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                ImportPaths(onScanOther = onImport, tonal = true)
            }
        }
        SheetRow(Glyphs.TextFields, "Enter setup key", "Type it in", cs.tertiaryContainer, cs.onTertiaryContainer, onManual)
        SheetRow(Glyphs.File, "Restore from backup", "From a Mydroid file", cs.surfaceContainerHighest, cs.onSurface, onRestore)
    }
}

@Composable
private fun SheetRow(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, sub: String, container: Color, tint: Color, onClick: () -> Unit) {
    Surface(onClick = onClick, Modifier.fillMaxWidth(), shape = RoundedCornerShape(20.dp), color = Color.Transparent) {
        Row(Modifier.heightIn(min = 64.dp).padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            IconBadge(icon, container, tint)
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.titleMedium)
                Text(sub, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun Locked(onUnlock: () -> Unit) {
    val cs = MaterialTheme.colorScheme
    Column(Modifier.fillMaxSize().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Box(Modifier.size(72.dp).clip(CircleShape).background(cs.secondaryContainer), contentAlignment = Alignment.Center) {
            Icon(Glyphs.Lock, null, Modifier.size(32.dp), tint = cs.onSecondaryContainer)
        }
        Spacer(Modifier.height(16.dp))
        Text("Codes are locked", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(6.dp))
        Text("Unlock to see them", style = MaterialTheme.typography.bodyMedium, color = cs.onSurfaceVariant, textAlign = TextAlign.Center)
        Spacer(Modifier.height(20.dp))
        Button(onUnlock, Modifier.heightIn(min = 52.dp), shape = RoundedCornerShape(18.dp)) { Text("Unlock") }
    }
}

@Composable
private fun Unreadable(api: AuthApi) {
    val cs = MaterialTheme.colorScheme
    Column(Modifier.fillMaxSize().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically)) {
        Icon(Icons.Default.Warning, null, Modifier.size(40.dp), tint = cs.error)
        Text("Can't open accounts", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
        Text("Android lost the key. Restore a backup to get them back.", style = MaterialTheme.typography.bodyMedium, color = cs.onSurfaceVariant, textAlign = TextAlign.Center)
        Button(api::beginRestore, Modifier.heightIn(min = 52.dp)) { Text("Restore from backup") }
        TextButton(api::scan) { Text("Scan QR code") }
    }
}

@Composable
internal fun BackupNudge(onBackup: () -> Unit, onDismiss: () -> Unit) {
    val cs = MaterialTheme.colorScheme
    Card28(color = cs.tertiaryContainer) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("Back up your accounts", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = cs.onTertiaryContainer)
            Text("In case you lose this phone", style = MaterialTheme.typography.bodyMedium, color = cs.onTertiaryContainer)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onBackup, Modifier.heightIn(min = 48.dp)) { Text("Back up") }
                TextButton(onDismiss, Modifier.heightIn(min = 48.dp)) { Text("Not now", color = cs.onTertiaryContainer) }
            }
        }
    }
}

@Composable
internal fun ImportCard(p: ImportProgress, onNext: () -> Unit, onCancel: () -> Unit) {
    val cs = MaterialTheme.colorScheme
    Card28(color = cs.primaryContainer) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("Importing from Google Authenticator", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = cs.onPrimaryContainer)
            Text("${p.scanned} of ${p.size} scanned", style = MaterialTheme.typography.headlineSmall, color = cs.onPrimaryContainer)
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                repeat(p.size) { i ->
                    val done = (i + 1) !in p.missing
                    Box(Modifier.weight(1f).height(8.dp).clip(RoundedCornerShape(50)).background(if (done) cs.primary else cs.onPrimaryContainer.copy(alpha = 0.18f)))
                }
            }
            Text("Google split them into ${p.size} QR codes", style = MaterialTheme.typography.bodyMedium, color = cs.onPrimaryContainer)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onNext, Modifier.heightIn(min = 48.dp)) { Text(if (p.missing.size == 1) "Scan part ${p.missing[0]}" else "Scan next") }
                TextButton(onCancel, Modifier.heightIn(min = 48.dp)) { Text("Cancel", color = cs.onPrimaryContainer) }
            }
        }
    }
}

// ---------------------------------------------------------------------------------------- manual and edit pages

@Composable
private fun PageHeader(title: String, onClose: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Top + WindowInsetsSides.Horizontal)).padding(start = 6.dp, end = 20.dp, top = 8.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClose, Modifier.size(48.dp).semantics { contentDescription = "Close" }) { Icon(Icons.Default.Close, null) }
        Spacer(Modifier.width(6.dp))
        Text(title, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
    }
}

private val noAutofillKeyboard = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Password)

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun ManualEntryContent(onSave: (AuthEntry) -> String?, onClose: () -> Unit, initialSecret: String = "", initialIssuer: String = "", initialAdvanced: Boolean = false) {
    var issuer by rememberSaveable { mutableStateOf(initialIssuer) }
    var account by rememberSaveable { mutableStateOf("") }
    var secret by rememberSaveable { mutableStateOf(initialSecret) }
    var showSecret by rememberSaveable { mutableStateOf(false) }
    var advanced by rememberSaveable { mutableStateOf(initialAdvanced) }
    var algorithm by rememberSaveable { mutableStateOf(OtpAlgorithm.SHA1) }
    var digits by rememberSaveable { mutableIntStateOf(6) }
    var period by rememberSaveable { mutableStateOf("30") }
    var hotp by rememberSaveable { mutableStateOf(false) }
    var counter by rememberSaveable { mutableStateOf("0") }
    var domains by rememberSaveable { mutableStateOf<List<String>?>(null) } // null = still the suggestion for the service
    var error by rememberSaveable { mutableStateOf<String?>(null) }
    val cs = MaterialTheme.colorScheme
    val secretOk = Base32.isValidSecret(secret)
    val suggested = remember(issuer) { IssuerDomains.forIssuer(issuer) }

    Column(Modifier.verticalScroll(rememberScrollState()).imePadding().windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom)).padding(horizontal = 20.dp).padding(top = 8.dp, bottom = 28.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        OutlinedTextField(issuer, { issuer = it; error = null }, Modifier.fillMaxWidth(), label = { Text("Service") }, placeholder = { Text("Salesforce") }, singleLine = true, shape = RoundedCornerShape(16.dp),
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words))
        OutlinedTextField(account, { account = it; error = null }, Modifier.fillMaxWidth(), label = { Text("Account") }, placeholder = { Text("you@example.com") }, singleLine = true, shape = RoundedCornerShape(16.dp),
            keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Email))
        OutlinedTextField(
            secret, { secret = it.uppercase(); error = null }, Modifier.fillMaxWidth(), label = { Text("Setup key") }, singleLine = true, shape = RoundedCornerShape(16.dp),
            visualTransformation = if (showSecret) VisualTransformation.None else PasswordVisualTransformation(), keyboardOptions = noAutofillKeyboard,
            trailingIcon = { TextButton({ showSecret = !showSecret }) { Text(if (showSecret) "Hide" else "Show") } },
            supportingText = { Text(if (secret.isNotBlank() && !secretOk) "Use A–Z and 2–7, 16 or more characters" else "Spaces are fine") },
            isError = secret.isNotBlank() && !secretOk,
        )
        TextButton({ advanced = !advanced }, Modifier.align(Alignment.Start)) { Text(if (advanced) "Hide advanced options" else "Advanced options") }
        AnimatedVisibility(advanced) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                ChipRow("Type", listOf("Time-based" to !hotp, "Counter-based" to hotp)) { hotp = it == 1 }
                ChipRow("Algorithm", OtpAlgorithm.entries.map { it.label to (it == algorithm) }) { algorithm = OtpAlgorithm.entries[it] }
                ChipRow("Digits", listOf("6" to (digits == 6), "7" to (digits == 7), "8" to (digits == 8))) { digits = it + 6 }
                if (hotp) OutlinedTextField(counter, { counter = it.filter(Char::isDigit).take(12) }, Modifier.fillMaxWidth(), label = { Text("Counter") }, singleLine = true, shape = RoundedCornerShape(16.dp), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                else OutlinedTextField(period, { period = it.filter(Char::isDigit).take(4) }, Modifier.fillMaxWidth(), label = { Text("Period (seconds)") }, singleLine = true, shape = RoundedCornerShape(16.dp), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                Text("Websites", style = MaterialTheme.typography.labelLarge, color = cs.primary)
                DomainEditor(domains ?: suggested, onChange = { domains = it }, hint = "Codes fill only on these sites")
            }
        }
        error?.let { Text(it, color = cs.error, style = MaterialTheme.typography.bodyMedium) }
        Button(
            onClick = {
                val e = AuthEntry(
                    issuer = issuer.trim(), account = account.trim(), secret = secret, algorithm = algorithm, digits = digits,
                    period = period.toIntOrNull()?.coerceIn(1, 3600) ?: 30, type = if (hotp) OtpType.HOTP else OtpType.TOTP, counter = counter.toLongOrNull() ?: 0,
                    domains = domains ?: suggested,
                )
                error = onSave(e)
                if (error == null) onClose()
            },
            enabled = secretOk, modifier = Modifier.fillMaxWidth().height(56.dp), shape = RoundedCornerShape(18.dp),
        ) { Text("Add account") }
    }
}

@Composable
private fun ManualPage(api: AuthApi, onClose: () -> Unit) {
    PageHeader("Enter setup key", onClose)
    ManualEntryContent(onSave = api::addManual, onClose = onClose)
}

@Composable
private fun ChipRow(label: String, options: List<Pair<String, Boolean>>, onPick: (Int) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(label, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            options.forEachIndexed { i, (t, sel) -> FilterChip(sel, { onPick(i) }, { Text(t) }, leadingIcon = if (sel) ({ Icon(Icons.Default.Check, null, Modifier.size(18.dp)) }) else null) }
        }
    }
}

/** Linked websites as chips, with a field to add one. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun DomainEditor(domains: List<String>, onChange: (List<String>) -> Unit, hint: String? = null) {
    var text by rememberSaveable { mutableStateOf("") }
    val cs = MaterialTheme.colorScheme
    fun add() {
        val d = Domains.normalize(text)
        if (Domains.isPlausibleHost(d)) { onChange((domains + d).distinct()); text = "" }
    }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (domains.isNotEmpty()) FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            domains.forEach { d ->
                InputChip(false, { onChange(domains - d) }, { Text(d) }, trailingIcon = { Icon(Icons.Default.Close, "Remove $d", Modifier.size(18.dp)) })
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(
                text, { text = it }, Modifier.weight(1f), label = { Text("Add a website") }, placeholder = { Text("example.com") }, singleLine = true, shape = RoundedCornerShape(16.dp),
                keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Uri),
            )
            FilledTonalButton(::add, Modifier.heightIn(min = 48.dp), enabled = Domains.isPlausibleHost(Domains.normalize(text))) { Text("Add") }
        }
        hint?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = cs.onSurfaceVariant) }
    }
}

@Composable
private fun EditPage(e: AuthEntry, api: AuthApi, onClose: () -> Unit) {
    var issuer by rememberSaveable(e.id) { mutableStateOf(e.issuer) }
    var account by rememberSaveable(e.id) { mutableStateOf(e.account) }
    var domains by rememberSaveable(e.id) { mutableStateOf(e.domains) }
    var confirmDelete by remember { mutableStateOf(false) }
    PageHeader("Edit account", onClose)
    Column(Modifier.verticalScroll(rememberScrollState()).imePadding().windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom)).padding(horizontal = 20.dp).padding(top = 8.dp, bottom = 28.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        OutlinedTextField(issuer, { issuer = it }, Modifier.fillMaxWidth(), label = { Text("Service") }, singleLine = true, shape = RoundedCornerShape(16.dp), keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words))
        OutlinedTextField(account, { account = it }, Modifier.fillMaxWidth(), label = { Text("Account") }, singleLine = true, shape = RoundedCornerShape(16.dp), keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Email))
        Text("Websites", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
        DomainEditor(domains, { domains = it }, hint = "Only on these sites and subdomains")
        Button({ api.save(e.copy(issuer = issuer.trim(), account = account.trim(), domains = domains)); onClose() }, Modifier.fillMaxWidth().height(56.dp), shape = RoundedCornerShape(18.dp)) { Text("Save") }
        OutlinedButton({ confirmDelete = true }, Modifier.fillMaxWidth().height(56.dp), shape = RoundedCornerShape(18.dp)) { Text("Delete account", color = MaterialTheme.colorScheme.error) }
    }
    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete ${e.title}?") },
            text = { Text("This can't be undone. Make sure you can still sign in another way.") },
            confirmButton = { TextButton({ confirmDelete = false; api.delete(e.id); onClose() }) { Text("Delete", color = MaterialTheme.colorScheme.error) } },
            dismissButton = { TextButton({ confirmDelete = false }) { Text("Cancel") } },
        )
    }
}

// ---------------------------------------------------------------------------------------- backup dialogs (shown over any screen)

/** Backup passphrase, restore passphrase, busy and the result snackbar. Lives at the app root so Settings and the Authenticator share it. */
@Composable
internal fun AuthOverlays(api: AuthApi) {
    val flow by api.flow.collectAsState()
    val notice by api.notice.collectAsState()
    val snack = remember { SnackbarHostState() }
    LaunchedEffect(notice) {
        val n = notice ?: return@LaunchedEffect
        api.consumeNotice()
        snack.showSnackbar(n, duration = SnackbarDuration.Long)
    }
    when (val f = flow) {
        AuthFlow.None -> {}
        AuthFlow.BackupForm -> SecureDialog(api::cancelFlow) { BackupPassphraseContent(onConfirm = api::confirmBackup, onCancel = api::cancelFlow) }
        is AuthFlow.RestorePassphrase -> SecureDialog(api::cancelFlow) { RestorePassphraseContent(f.wrong, onConfirm = api::confirmRestore, onCancel = api::cancelFlow) }
        is AuthFlow.Busy -> SecureDialog({}) {
            Row(Modifier.padding(24.dp), verticalAlignment = Alignment.CenterVertically) { CircularProgressIndicator(Modifier.size(28.dp), strokeWidth = 3.dp); Spacer(Modifier.width(16.dp)); Text(f.what) }
        }
    }
    Box(Modifier.fillMaxSize()) {
        SnackbarHost(snack, Modifier.align(Alignment.BottomCenter).windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Bottom + WindowInsetsSides.Horizontal)).padding(16.dp))
    }
}

@Composable
private fun SecureDialog(onDismiss: () -> Unit, content: @Composable () -> Unit) {
    androidx.compose.ui.window.Dialog(onDismiss, DialogProperties(securePolicy = SecureFlagPolicy.SecureOn, usePlatformDefaultWidth = true)) {
        Surface(shape = RoundedCornerShape(28.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh, tonalElevation = 3.dp) { content() }
    }
}

private val strengthLabel = mapOf(
    PassphraseStrength.Level.Weak to "Weak. Use 8 or more characters",
    PassphraseStrength.Level.Fair to "Fair",
    PassphraseStrength.Level.Good to "Good",
    PassphraseStrength.Level.Strong to "Strong",
)

@Composable
internal fun BackupPassphraseContent(onConfirm: (CharArray) -> Unit, onCancel: () -> Unit, initialPass: String = "", initialConfirm: String = "", showText: Boolean = false) {
    var pass by remember { mutableStateOf(initialPass) }
    var again by remember { mutableStateOf(initialConfirm) }
    var show by remember { mutableStateOf(showText) }
    val cs = MaterialTheme.colorScheme
    val level = PassphraseStrength.level(pass)
    val match = pass.isNotEmpty() && pass == again
    val vt = if (show) VisualTransformation.None else PasswordVisualTransformation()
    Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Back up your accounts", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
        Text("Saved to one file. If you forget the passphrase, it can't be recovered.", style = MaterialTheme.typography.bodyMedium, color = cs.onSurfaceVariant)
        OutlinedTextField(pass, { pass = it }, Modifier.fillMaxWidth(), label = { Text("Passphrase") }, singleLine = true, shape = RoundedCornerShape(16.dp), visualTransformation = vt, keyboardOptions = noAutofillKeyboard)
        if (pass.isNotEmpty()) {
            val colors = listOf(cs.error, Color(0xFFE0A100), Color(0xFF4C9F50), Color(0xFF1E8E3E))
            val c = colors[level.ordinal]
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                repeat(4) { i -> Box(Modifier.weight(1f).height(6.dp).clip(RoundedCornerShape(50)).background(if (i <= level.ordinal) c else cs.surfaceContainerHighest)) }
            }
            Text(strengthLabel.getValue(level), style = MaterialTheme.typography.bodySmall, color = if (level == PassphraseStrength.Level.Weak) cs.error else cs.onSurfaceVariant)
        }
        OutlinedTextField(
            again, { again = it }, Modifier.fillMaxWidth(), label = { Text("Type it again") }, singleLine = true, shape = RoundedCornerShape(16.dp), visualTransformation = vt, keyboardOptions = noAutofillKeyboard,
            isError = again.isNotEmpty() && !match, supportingText = if (again.isNotEmpty() && !match) ({ Text("Doesn't match") }) else null,
        )
        Row(verticalAlignment = Alignment.CenterVertically) {
            Checkbox(show, { show = it }); Text("Show", style = MaterialTheme.typography.bodyMedium)
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            TextButton(onCancel) { Text("Cancel") }
            Spacer(Modifier.width(8.dp))
            Button({ onConfirm(pass.toCharArray()) }, enabled = match && level != PassphraseStrength.Level.Weak) { Text("Choose location") }
        }
    }
}

@Composable
internal fun RestorePassphraseContent(wrong: Boolean, onConfirm: (CharArray) -> Unit, onCancel: () -> Unit) {
    var pass by remember { mutableStateOf("") }
    Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Restore from backup", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
        Text("Enter the backup passphrase", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        OutlinedTextField(
            pass, { pass = it }, Modifier.fillMaxWidth(), label = { Text("Passphrase") }, singleLine = true, shape = RoundedCornerShape(16.dp),
            visualTransformation = PasswordVisualTransformation(), keyboardOptions = noAutofillKeyboard,
            isError = wrong, supportingText = if (wrong) ({ Text("Wrong passphrase") }) else null,
        )
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            TextButton(onCancel) { Text("Cancel") }
            Spacer(Modifier.width(8.dp))
            Button({ onConfirm(pass.toCharArray()) }, enabled = pass.isNotEmpty()) { Text("Restore") }
        }
    }
}

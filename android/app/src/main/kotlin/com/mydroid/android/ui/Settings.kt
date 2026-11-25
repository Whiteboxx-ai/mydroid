package com.mydroid.android.ui

import android.os.Build
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.mydroid.android.*
import com.mydroid.android.callaudio.CallAudioState
import com.mydroid.android.fix.Oem
import com.mydroid.android.net.Link
import com.mydroid.android.net.UiState
import com.mydroid.android.presence.PresenceStatus
import com.mydroid.android.presence.Presence

private enum class Tone { Ok, Warn, Quiet }

/** One line in Settings: a title, one short [status], and at most one [action]. A [toggle] replaces the button with a switch; [info] adds an ⓘ. */
private class SettingRow(
    val icon: ImageVector,
    val title: String,
    val status: String?,
    val tone: Tone = Tone.Quiet,
    val action: String? = null,
    val onAction: () -> Unit = {},
    val toggle: Boolean? = null,
    val onToggle: (Boolean) -> Unit = {},
    val info: Info? = null,
    val danger: Boolean = false,
    /** Whole-row tap, for destructive rows that go straight to a confirmation. */
    val onClick: (() -> Unit)? = null,
)

private class SettingGroup(val title: String, val rows: List<SettingRow>)

@Composable
internal fun SettingsScreen(s: UiState, a: Actions, now: Long, version: String, onBack: () -> Unit) {
    val ctx = LocalContext.current
    var confirmUnpair by remember { mutableStateOf(false) }
    var explainInstant by remember { mutableStateOf(false) }
    var pickApprove by remember { mutableStateOf(false) }
    var deleteStep by remember { mutableIntStateOf(0) } // 0 closed, 1 first question, 2 are you sure
    val killedAt = remember(s.oemOpenedAt, now) { runCatching { Oem.needsAutoStart(ctx, s.oemOpenedAt) }.getOrNull() }
    val autoStartTip = remember { runCatching { Oem.autoStartIntent(ctx) != null }.getOrDefault(false) }
    val groups = settingGroups(s, a, now, killedAt, autoStartTip, version, onUnpair = { confirmUnpair = true }, onExplainInstant = { explainInstant = true },
        onApprove = { pickApprove = true }, onDeleteAll = { deleteStep = 1 })

    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Top + WindowInsetsSides.Horizontal)).padding(start = 6.dp, end = 20.dp, top = 8.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onBack, Modifier.size(48.dp).semantics { contentDescription = "Back" }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, null) }
            Spacer(Modifier.width(6.dp))
            Text("Settings", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold)
        }
        Column(
            Modifier.weight(1f).verticalScroll(rememberScrollState())
                .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom))
                .padding(horizontal = 20.dp).padding(top = 12.dp, bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            groups.forEach { g ->
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    SectionLabel(g.title)
                    Card28 {
                        g.rows.forEachIndexed { i, r ->
                            if (i > 0) HorizontalDivider(Modifier.padding(start = 70.dp, end = 16.dp), color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f))
                            SettingLine(r)
                        }
                    }
                }
            }
        }
    }

    if (confirmUnpair) {
        AlertDialog(
            onDismissRequest = { confirmUnpair = false },
            title = { Text("Unpair from ${s.macName}?") },
            text = { Text("Syncing stops. Scan a new code to pair again.") },
            confirmButton = { TextButton(onClick = { confirmUnpair = false; a.unpair() }) { Text("Unpair", color = MaterialTheme.colorScheme.error) } },
            dismissButton = { TextButton(onClick = { confirmUnpair = false }) { Text("Cancel") } },
        )
    }
    if (pickApprove) ApproveModeDialog(s.auth, onPick = { m, min -> pickApprove = false; a.auth.setApproveMode(m, min) }, onDismiss = { pickApprove = false })
    if (deleteStep == 1) {
        AlertDialog(
            onDismissRequest = { deleteStep = 0 },
            title = { Text("Delete all accounts?") },
            text = { Text("Removes ${plural(s.auth.count, "account", "accounts")} from this phone. Without a backup, you'll set each one up again.") },
            confirmButton = { TextButton({ deleteStep = 2 }) { Text("Continue", color = MaterialTheme.colorScheme.error) } },
            dismissButton = { TextButton({ deleteStep = 0 }) { Text("Cancel") } },
        )
    }
    if (deleteStep == 2) {
        AlertDialog(
            onDismissRequest = { deleteStep = 0 },
            title = { Text("Delete everything?") },
            text = { Text("This can't be undone.") },
            confirmButton = { TextButton({ deleteStep = 0; a.auth.deleteAll() }) { Text("Delete all", color = MaterialTheme.colorScheme.error) } },
            dismissButton = { TextButton({ deleteStep = 0 }) { Text("Cancel") } },
        )
    }
    if (explainInstant) {
        AlertDialog(
            onDismissRequest = { explainInstant = false },
            title = { Text("Turn on Instant copy?") },
            text = { Text("It uses Android's accessibility permission. Some banking and UPI apps show a security warning while it's on.") },
            confirmButton = { TextButton(onClick = { explainInstant = false; a.setInstantCopy(true); a.allowClipboard() }) { Text("Turn on") } },
            dismissButton = { TextButton(onClick = { explainInstant = false }) { Text("Not now") } },
        )
    }
}

@Composable
private fun settingGroups(
    s: UiState, a: Actions, now: Long, killedAt: Long?, autoStartTip: Boolean, version: String,
    onUnpair: () -> Unit, onExplainInstant: () -> Unit, onApprove: () -> Unit, onDeleteAll: () -> Unit,
): List<SettingGroup> {
    val set = s.settings
    val r = s.report
    val connected = s.link == Link.Connected
    val restricted = "If Android says it's restricted, open Mydroid's app info, tap ⋮ and choose Allow restricted settings."
    // A feature switched off on the Mac has nothing to show here, so its rows are left out.
    fun row(icon: ImageVector, title: String, ok: Boolean, good: String, bad: String, action: String = "Allow", info: Info? = null, run: () -> Unit) =
        SettingRow(icon, title, if (ok) good else bad, if (ok) Tone.Ok else Tone.Warn, if (ok) null else action, run, info = info)

    return buildList {
        // ---- Connection
        add(SettingGroup("Connection", buildList {
            add(SettingRow(
                Glyphs.Laptop, s.macName.replaceFirstChar { it.uppercase() },
                if (connected) "Connected" else if (s.lastSeen > 0) "Last seen ${ago(s.lastSeen, now)}" else "Looking for your Mac…",
                if (connected) Tone.Ok else Tone.Quiet,
            ))
            if (r.presence != PresenceStatus.Unsupported) {
                // One row for nearby detection and, where needed, codes from apps.
                val ready = r.presence == PresenceStatus.Ready
                val canUnhide = Presence.offerWatchProfile(set?.notifications == true)
                val done = ready && r.bluetoothOn && (r.codesFromApps || !canUnhide)
                add(SettingRow(
                    Glyphs.Laptop, "Your Mac nearby",
                    when {
                        done -> "On"
                        !r.bluetoothOn -> "Bluetooth is off"
                        else -> "Not set up"
                    },
                    if (done) Tone.Ok else Tone.Quiet,
                    if (done) null else "Set up", a.allowPresence,
                    info = Info(
                        "Your Mac nearby",
                        if (canUnhide) "Mydroid wakes only when your Mac is close, which saves battery, and shows codes from apps on your Mac. It uses Bluetooth, never your location. Android's dialog calls your Mac a “watch”; that's expected."
                        else "Mydroid wakes only when your Mac is close, which saves battery. It uses Bluetooth, never your location.",
                    ),
                ))
            }
            if (set?.walkAway == true) {
                // Set on the Mac. Android needs "Nearby devices" here for the phone to send the Bluetooth beacon the Mac listens for.
                when (r.walkAway) {
                    com.mydroid.android.walkaway.WalkAwayStatus.NeedsPermission ->
                        add(SettingRow(Glyphs.Lock, "Walk-away lock", "Needs Nearby devices", Tone.Warn, "Allow", a.allowWalkAway))
                    com.mydroid.android.walkaway.WalkAwayStatus.BluetoothOff ->
                        add(SettingRow(Glyphs.Lock, "Walk-away lock", "Bluetooth is off", Tone.Warn))
                    com.mydroid.android.walkaway.WalkAwayStatus.Unsupported -> {}
                    else ->
                        add(SettingRow(Glyphs.Lock, "Walk-away lock", "On", Tone.Ok, info = Info("Walk-away lock", "Your Mac locks when you walk away with this phone. It works while Mydroid is connected.")))
                }
            }
            add(when {
                r.backgroundRestricted -> SettingRow(Glyphs.Battery, "Stay connected", "Background activity restricted", Tone.Warn, "Fix", a.openAppInfo,
                    info = Info("Stay connected", Oem.backgroundHelp))
                killedAt != null -> SettingRow(Glyphs.Battery, "Stay connected", "Mydroid stopped in the background ${ago(killedAt, now)}", Tone.Warn, "Fix", a.openOem)
                else -> SettingRow(Glyphs.Battery, "Android background restriction", "None reported", Tone.Quiet)
            })
            if (Oem.hasSeparateBackgroundControls && !r.backgroundRestricted) {
                add(SettingRow(
                    Glyphs.Battery, "${Oem.brandName} battery settings", "Check background activity",
                    Tone.Quiet, "Open app info", a.openAppInfo,
                    info = Info("Background activity", Oem.backgroundHelp),
                ))
            }
            add(SettingRow(
                Glyphs.Battery, "Battery optimization",
                if (r.batteryOptimizationExempt) "Exempt" else "Standard",
                Tone.Quiet, if (r.batteryOptimizationExempt) "Open settings" else "Allow while idle", a.openBatteryOptimization,
                info = Info("Battery optimization", "Exempt shows Android’s battery setting. Allowing sync while idle can increase battery use."),
            ))
            if (!r.backgroundRestricted && autoStartTip && killedAt == null) {
                add(SettingRow(
                    Icons.Default.Info, "Auto-start", "Optional", Tone.Quiet, "Open", a.openOem,
                    info = Info("Auto-start", "Some ${Oem.brandName} phones close background apps anyway. Android can't check this setting, so Mydroid only asks again if it gets closed."),
                ))
            }
            add(SettingRow(Icons.Default.Warning, "Unpair this Mac", null, Tone.Quiet, danger = true, onClick = onUnpair))
        }))

        // ---- Notifications & codes
        if (set?.notifications == true || (Build.VERSION.SDK_INT >= 33 && !r.postNotifications)) add(SettingGroup("Notifications & codes", buildList {
            if (Build.VERSION.SDK_INT >= 33 && !r.postNotifications) {
                add(SettingRow(Icons.Default.Notifications, "Mydroid alerts", "Off", Tone.Quiet, "Allow", a.allowAlerts))
            }
            if (set?.notifications != true) return@buildList
            val notifOn = r.state(Feature.Notifications) == FeatureState.On
            add(row(Icons.Default.Notifications, "Notifications", notifOn, "Shown on your Mac", "Needs access", info = if (notifOn) null else Info("Notification access", restricted), run = a.allowNotificationAccess))
            if (r.supportsTexts) add(row(Icons.Default.Notifications, "Verification codes", r.otp == FeatureState.On, "Shown on your Mac", "Needs permission",
                info = Info("Verification codes", "Mydroid looks for codes in new texts and never stores them."), run = a.allowSms))
            if (Presence.offerWatchProfile(true) && r.presence != PresenceStatus.Unsupported) {
                // Status only; set up through "Your Mac nearby" (same single Bluetooth approval).
                add(SettingRow(
                    Icons.Default.Notifications, "Codes from apps",
                    if (r.codesFromApps) "Companion paired" else "May be hidden by Android",
                    if (r.codesFromApps) Tone.Ok else Tone.Quiet, if (r.codesFromApps) null else "Set up", a.allowPresence,
                    info = Info("Codes from apps", "Android can still hide some notifications. Open them on your phone to see the code."),
                ))
            }
        }))

        // ---- Photos
        if (set?.photos == true) add(SettingGroup("Photos", buildList {
            val on = r.state(Feature.Photos) == FeatureState.On
            add(SettingRow(
                Glyphs.Photo, "Camera roll",
                when {
                    !on -> "Needs access"
                    r.photosPartial -> "Only some photos"
                    s.photosWaiting == 0 -> "Up to date"
                    s.photosWaiting == 1 -> "1 photo waiting"
                    else -> "${s.photosWaiting} photos waiting"
                },
                if (on && !r.photosPartial) Tone.Ok else Tone.Warn,
                if (!on) "Allow" else if (r.photosPartial) "Allow all" else null, a.allowPhotos,
            ))
            add(SettingRow(Glyphs.Photo, "Screenshots", if (set.screenshots) "Included" else "Not included"))
        }))

        // ---- Calls
        if (r.supportsCalls && set?.calls == true) add(SettingGroup("Calls", buildList {
            val on = r.state(Feature.Calls) == FeatureState.On
            val full = on && !r.callsMissingOptional
            add(SettingRow(
                Icons.Default.Call, "Calls on your Mac",
                when {
                    !on -> "Needs phone access"
                    r.callsMissingOptional -> "Names and history need access"
                    else -> "Shown on your Mac"
                },
                if (full) Tone.Ok else Tone.Warn, if (full) null else "Allow", a.allowCalls,
            ))
            add(SettingRow(
                Icons.Default.Call, "Call from your Mac", if (r.dial) "On" else "Needs permission", if (r.dial) Tone.Ok else Tone.Warn, if (r.dial) null else "Allow", a.allowDial,
                info = Info("Call from your Mac", "Start calls on your Mac and your phone places them. Audio stays on your phone unless you turn on Hear calls on your Mac."),
            ))
            // Optional and set up on the Mac, so never an error and never a button.
            val ca = r.callAudio.state
            add(SettingRow(
                Glyphs.Laptop, "Hear calls on your Mac",
                when {
                    ca == CallAudioState.On -> "On"
                    ca == CallAudioState.Off && r.callAudioEver -> "Off"
                    else -> "Set up on your Mac"
                },
                if (ca == CallAudioState.On) Tone.Ok else Tone.Quiet,
            ))
        }))

        // ---- Clipboard
        if (set?.clipboard == true) add(SettingGroup("Clipboard", buildList {
            add(SettingRow(
                Glyphs.Clipboard, "Send to your Mac", "On", Tone.Ok,
                info = Info("Send to your Mac", "Use Paste on Home, Send to Mac in the text selection menu, or the notification button."),
            ))
            val live = r.instantCopy && r.a11yEnabled
            add(SettingRow(
                Glyphs.Clipboard, "Instant copy",
                when {
                    live -> "On"
                    r.instantCopy -> "Finish in Accessibility"
                    else -> "Off"
                },
                if (live) Tone.Ok else Tone.Quiet,
                action = if (r.instantCopy && !r.a11yEnabled) "Open" else null, onAction = a.allowClipboard,
                toggle = r.instantCopy, onToggle = { if (it) onExplainInstant() else a.setInstantCopy(false) },
                info = Info("Instant copy", "Sends text the moment you tap Copy. It uses Android's accessibility permission. Some banking and UPI apps show a security warning while it's on."),
            ))
            if (r.instantStray) add(SettingRow(Icons.Default.Warning, "Instant copy is on", "In Accessibility settings", Tone.Warn, "Open", a.allowClipboard))
        }))

        // ---- Messages
        if (r.supportsTexts && set?.smsHistory == true) add(SettingGroup("Messages", buildList {
            val on = r.state(Feature.Sms) == FeatureState.On
            add(row(Icons.Default.Email, "Text from your Mac", on, "On", "Needs permission",
                info = Info("Text from your Mac", "Mydroid reads your texts only when your Mac asks. $restricted"), run = a.allowSmsHistory))
        }))

        // ---- Authenticator
        add(SettingGroup("Authenticator", buildList {
            val au = s.auth
            add(SettingRow(
                Glyphs.Lock, "Lock codes",
                when {
                    !au.canGate -> "Set a screen lock first"
                    au.requireBiometric -> "On"
                    else -> "Off"
                },
                if (au.requireBiometric && au.canGate) Tone.Ok else Tone.Quiet,
                toggle = au.requireBiometric, onToggle = a.auth::setRequireBiometric,
                info = Info("Lock codes", "Asks for your fingerprint, face or screen lock before codes show, and again after a minute away."),
            ))
            val auto = au.approveMode == com.mydroid.protocol.auth.ApprovalPolicy.Mode.Auto
            add(SettingRow(
                Glyphs.Key, "Approve fills",
                when {
                    !auto -> "Ask every time"
                    r.presenceReady() -> "Automatic, within ${au.autoMinutes} min"
                    else -> "Needs Your Mac nearby"
                },
                if (auto) (if (r.presenceReady()) Tone.Ok else Tone.Warn) else Tone.Quiet, "Change", onApprove,
                info = Info("Approve fills", "Ask every time sends a notification with Approve and Deny. Automatic approves while your phone is unlocked and your Mac is nearby; otherwise it asks."),
            ))
            if (au.count > 0) add(SettingRow(
                Glyphs.File, "Back up accounts",
                when {
                    au.lastBackupAt > 0 -> "Last backup ${java.text.DateFormat.getDateInstance(java.text.DateFormat.MEDIUM).format(java.util.Date(au.lastBackupAt))}"
                    else -> "Not backed up"
                },
                if (au.nudge) Tone.Warn else Tone.Quiet, "Export", a.auth::beginBackup,
                info = Info("Back up accounts", "A backup is one encrypted file only your passphrase opens. Without one, a lost phone loses these accounts."),
            ))
            add(SettingRow(Glyphs.Folder, "Restore from backup", null, Tone.Quiet, "Import", a.auth::beginRestore))
            if (au.count > 0) add(SettingRow(Icons.Default.Warning, "Delete all accounts", plural(au.count, "account", "accounts"), Tone.Quiet, danger = true, onClick = onDeleteAll))
        }))

        // ---- Files
        add(SettingGroup("Files", listOf(
            SettingRow(Glyphs.Folder, "Your Mac in Files", null, Tone.Quiet, "Open", a.openMacFiles),
        )))

        // ---- About
        add(SettingGroup("About", listOf(
            SettingRow(Glyphs.Phone, "Mydroid", "Version $version"),
        )))
    }
}

@Composable
private fun SettingLine(r: SettingRow) {
    val cs = MaterialTheme.colorScheme
    val (container, tint) = when {
        r.danger -> cs.errorContainer to cs.onErrorContainer
        r.tone == Tone.Warn -> cs.errorContainer to cs.onErrorContainer
        r.tone == Tone.Ok -> cs.primaryContainer to cs.onPrimaryContainer
        else -> cs.surfaceContainerHighest to cs.onSurfaceVariant
    }
    val click = if (r.onClick != null) Modifier.clickable(onClick = r.onClick) else Modifier
    // With large text a trailing button would squeeze the words, so it drops under them.
    val stacked = androidx.compose.ui.platform.LocalDensity.current.fontScale > 1.15f
    val trailingAction = r.action != null && !stacked
    Row(
        Modifier.fillMaxWidth().then(click).heightIn(min = 64.dp).padding(start = 16.dp, end = if (r.info != null || r.toggle != null || trailingAction) 8.dp else 16.dp, top = 8.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconBadge(r.icon, container, tint)
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(r.title, style = MaterialTheme.typography.titleMedium, color = if (r.danger) cs.error else cs.onSurface)
            if (r.status != null) androidx.compose.animation.Crossfade(r.status, label = "status") {
                Text(it, style = MaterialTheme.typography.bodyMedium, color = if (r.tone == Tone.Warn) cs.error else cs.onSurfaceVariant)
            }
            if (r.action != null && stacked) {
                Spacer(Modifier.height(8.dp))
                ActionButton(r)
            }
        }
        if (r.info != null) InfoButton(r.info)
        if (trailingAction) { Spacer(Modifier.width(4.dp)); ActionButton(r) }
        if (r.toggle != null) {
            Spacer(Modifier.width(4.dp))
            Switch(checked = r.toggle, onCheckedChange = r.onToggle, modifier = Modifier.padding(end = 8.dp))
        }
    }
}

@Composable
private fun ActionButton(r: SettingRow) {
    if (r.tone == Tone.Warn) Button(onClick = r.onAction, contentPadding = PaddingValues(horizontal = 16.dp)) { Text(r.action ?: "", maxLines = 1) }
    else FilledTonalButton(onClick = r.onAction, contentPadding = PaddingValues(horizontal = 16.dp)) { Text(r.action ?: "", maxLines = 1) }
}

/** "Approve automatically" needs the Bluetooth presence proof; without it the phone always asks. */
private fun FeatureReport.presenceReady() = presence == PresenceStatus.Ready

@Composable
internal fun ApproveModeDialog(au: com.mydroid.android.auth.AuthUi, onPick: (com.mydroid.protocol.auth.ApprovalPolicy.Mode, Int) -> Unit, onDismiss: () -> Unit) {
    var auto by remember { mutableStateOf(au.approveMode == com.mydroid.protocol.auth.ApprovalPolicy.Mode.Auto) }
    var minutes by remember { mutableIntStateOf(au.autoMinutes) }
    val sub = MaterialTheme.typography.bodyMedium
    val subColor = MaterialTheme.colorScheme.onSurfaceVariant
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Approve fills") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(Modifier.fillMaxWidth().heightIn(min = 56.dp), verticalAlignment = Alignment.CenterVertically) {
                    RadioButton(!auto, { auto = false })
                    Column(Modifier.padding(start = 4.dp)) { Text("Ask every time"); Text("Approve in a notification", style = sub, color = subColor) }
                }
                Row(Modifier.fillMaxWidth().heightIn(min = 56.dp), verticalAlignment = Alignment.CenterVertically) {
                    RadioButton(auto, { auto = true })
                    Column(Modifier.padding(start = 4.dp)) { Text("Automatic"); Text("When unlocked and nearby", style = sub, color = subColor) }
                }
                if (auto) {
                    Text("Unlocked within", Modifier.padding(top = 8.dp), style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
                    @OptIn(ExperimentalLayoutApi::class)
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        listOf(1, 5, 10, 15, 30).forEach { m -> FilterChip(minutes == m, { minutes = m }, { Text("$m min") }) }
                    }
                }
            }
        },
        confirmButton = { TextButton({ onPick(if (auto) com.mydroid.protocol.auth.ApprovalPolicy.Mode.Auto else com.mydroid.protocol.auth.ApprovalPolicy.Mode.Ask, minutes) }) { Text("Save") } },
        dismissButton = { TextButton(onDismiss) { Text("Cancel") } },
    )
}

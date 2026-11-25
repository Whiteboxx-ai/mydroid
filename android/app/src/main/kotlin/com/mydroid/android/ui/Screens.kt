package com.mydroid.android.ui

import android.os.Build
import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.lifecycle.repeatOnLifecycle
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mydroid.android.*
import com.mydroid.android.fix.Oem
import com.mydroid.android.net.Link
import com.mydroid.android.net.UiState
import com.mydroid.android.presence.Presence
import com.mydroid.android.presence.PresenceStatus
import kotlinx.coroutines.delay

private enum class Screen { Welcome, Confirm, Permissions, Home, Settings, Remote, Authenticator }

/** Wall-clock time that refreshes every 30 s while the screen is showing; a stopped activity must not keep a timer alive. */
@Composable
private fun rememberNow(): Long {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    val lifecycleOwner = androidx.lifecycle.compose.LocalLifecycleOwner.current
    LaunchedEffect(lifecycleOwner) {
        lifecycleOwner.lifecycle.repeatOnLifecycle(androidx.lifecycle.Lifecycle.State.STARTED) {
            while (true) { now = System.currentTimeMillis(); delay(30_000) }
        }
    }
    return now
}

@Composable
fun MydroidApp(s: UiState, a: Actions) {
    var settingsOpen by rememberSaveable { mutableStateOf(false) }
    var remoteOpen by rememberSaveable { mutableStateOf(false) }
    var authOpen by rememberSaveable { mutableStateOf(false) }
    var remoteTab by rememberSaveable { mutableStateOf(RemoteTab.Pad.name) }
    var timerStart by rememberSaveable { mutableLongStateOf(0L) }
    val now = rememberNow()
    val ready = s.link != Link.Confirm && s.link != Link.Unpaired && s.link != Link.Connecting && s.setupDone
    // Unpairing (or losing the pairing) while Settings is open lands on Welcome; don't come back to Settings later.
    LaunchedEffect(ready) { if (!ready) { settingsOpen = false; remoteOpen = false; authOpen = false } }
    // The "Presenting on your Mac? Tap for clicker" notification asks for a Remote mode.
    LaunchedEffect(s.openRemote, ready) {
        val want = s.openRemote ?: return@LaunchedEffect
        if (!ready) return@LaunchedEffect
        RemoteTab.fromName(want)?.let { remoteTab = it.name }
        if (timerStart == 0L) timerStart = System.currentTimeMillis()
        settingsOpen = false; remoteOpen = true
        a.consumeOpenRemote()
    }
    LaunchedEffect(remoteOpen) { if (!remoteOpen) timerStart = 0L } // the next presentation starts its timer from zero
    androidx.activity.compose.BackHandler(enabled = remoteOpen && ready) { remoteOpen = false }
    androidx.activity.compose.BackHandler(enabled = authOpen && ready && !remoteOpen) { authOpen = false }
    androidx.activity.compose.BackHandler(enabled = settingsOpen && ready && !remoteOpen) { settingsOpen = false }
    val screen = when {
        s.link == Link.Confirm -> Screen.Confirm
        s.link == Link.Unpaired || s.link == Link.Connecting -> Screen.Welcome
        !s.setupDone -> Screen.Permissions
        remoteOpen -> Screen.Remote
        authOpen -> Screen.Authenticator
        settingsOpen -> Screen.Settings
        else -> Screen.Home
    }
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
      Box(Modifier.fillMaxSize()) {
        AnimatedContent(
            targetState = screen,
            transitionSpec = {
                val forward = targetState.ordinal >= initialState.ordinal
                (fadeIn(tween(320)) + slideInHorizontally(tween(380, easing = FastOutSlowInEasing)) { if (forward) it / 6 else -it / 6 }) togetherWith
                    (fadeOut(tween(180)) + slideOutHorizontally(tween(380, easing = FastOutSlowInEasing)) { if (forward) -it / 6 else it / 6 })
            },
            label = "screen",
        ) { sc ->
            when (sc) {
                Screen.Welcome -> WelcomeScreen(s, a)
                Screen.Confirm -> ConfirmScreen(s, a)
                Screen.Permissions -> PermissionsScreen(s, a)
                Screen.Home -> HomeScreen(s, a, now, onSettings = { settingsOpen = true }, onRemote = { remoteOpen = true }, onAuth = { authOpen = true })
                Screen.Remote -> {
                    val tab = RemoteTab.entries.firstOrNull { it.name == remoteTab } ?: RemoteTab.Pad
                    RemoteScreen(
                        s, a.remote, tab,
                        onTab = { remoteTab = it.name; if (it == RemoteTab.Present && timerStart == 0L) timerStart = System.currentTimeMillis() },
                        onBack = { remoteOpen = false },
                        timerStart = timerStart.takeIf { it > 0 } ?: now, onTimerReset = { timerStart = System.currentTimeMillis() },
                    )
                }
                Screen.Authenticator -> AuthenticatorScreen(s, a.auth, onBack = { authOpen = false })
                Screen.Settings -> SettingsScreen(s, a, now, BuildConfig.VERSION_NAME, onBack = { settingsOpen = false })
            }
        }
        AuthOverlays(a.auth)
      }
    }
}

// ---------------------------------------------------------------------------------------- Welcome

@Composable
internal fun WelcomeScreen(s: UiState, a: Actions) {
    val busy = s.link == Link.Connecting
    Column(
        Modifier.fillMaxSize().safeDrawingPadding().padding(horizontal = 28.dp, vertical = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.weight(1f))
        PairIllustration()
        Spacer(Modifier.height(36.dp))
        Text("Your phone, on your Mac", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
        Spacer(Modifier.height(12.dp))
        Text(
            "Reply and share files from your Mac",
            style = MaterialTheme.typography.bodyLarge, textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.weight(1f))
        AnimatedVisibility(visible = s.message != null, enter = fadeIn() + expandVertically(), exit = fadeOut() + shrinkVertically()) {
            Card(
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer),
                modifier = Modifier.padding(bottom = 16.dp).fillMaxWidth(),
            ) {
                Text(s.message ?: "", Modifier.padding(16.dp), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSecondaryContainer)
            }
        }
        if (busy) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(bottom = 16.dp)) {
                CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.5.dp)
                Spacer(Modifier.width(12.dp))
                Text("Connecting to your Mac…", style = MaterialTheme.typography.bodyMedium)
            }
        }
        Button(
            onClick = a.scan, enabled = !busy,
            modifier = Modifier.fillMaxWidth().height(60.dp), shape = RoundedCornerShape(20.dp),
        ) {
            Icon(Glyphs.QrScan, null)
            Spacer(Modifier.width(10.dp))
            Text("Scan code on your Mac", style = MaterialTheme.typography.titleMedium)
        }
        if (busy) TextButton(onClick = a.cancelPairing) { Text("Cancel") }
    }
}

@Composable
private fun PairIllustration() {
    val t = rememberInfiniteTransition(label = "pulse")
    val pulse by t.animateFloat(0.92f, 1.06f, infiniteRepeatable(tween(1800, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "p")
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Box(Modifier.size(84.dp).clip(RoundedCornerShape(24.dp)).background(MaterialTheme.colorScheme.primaryContainer), contentAlignment = Alignment.Center) {
            Icon(Glyphs.Phone, null, Modifier.size(44.dp), tint = MaterialTheme.colorScheme.onPrimaryContainer)
        }
        Box(Modifier.size(10.dp).scale(pulse).clip(CircleShape).background(MaterialTheme.colorScheme.primary))
        Box(Modifier.size(84.dp).clip(RoundedCornerShape(24.dp)).background(MaterialTheme.colorScheme.secondaryContainer), contentAlignment = Alignment.Center) {
            Icon(Glyphs.Laptop, null, Modifier.size(44.dp), tint = MaterialTheme.colorScheme.onSecondaryContainer)
        }
    }
}

// ---------------------------------------------------------------------------------------- Confirm

@Composable
internal fun ConfirmScreen(s: UiState, a: Actions) {
    Column(
        Modifier.fillMaxSize().safeDrawingPadding().padding(28.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.weight(1f))
        Text("Match the code on your Mac", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
        Spacer(Modifier.height(32.dp))
        // Always one line: scale the digits to the width we have (narrow phones, large font settings).
        BoxWithConstraints(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            val code = s.code ?: ""
            val density = androidx.compose.ui.platform.LocalDensity.current
            val padH = 28.dp
            val availablePx = with(density) { (maxWidth - padH * 2).toPx() }
            // Monospace glyphs are ~0.6em wide, plus letter spacing; keep a little slack.
            val fitPx = availablePx / (code.length.coerceAtLeast(1) * 0.68f)
            val fitSp = fitPx / (density.density * density.fontScale)
            val size = minOf(56f, fitSp).sp
            Surface(shape = RoundedCornerShape(28.dp), color = MaterialTheme.colorScheme.primaryContainer) {
                Text(
                    code, Modifier.padding(horizontal = padH, vertical = 24.dp),
                    fontSize = size, lineHeight = size * 1.15f, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onPrimaryContainer, letterSpacing = 1.sp,
                    maxLines = 1, softWrap = false,
                )
            }
        }
        Spacer(Modifier.height(28.dp))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.Center) {
            CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
            Spacer(Modifier.width(12.dp))
            Text(
                "Click “Codes match” on your Mac", Modifier.weight(1f, fill = false),
                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center,
            )
        }
        Spacer(Modifier.weight(1f))
        TextButton(onClick = a.cancelPairing) { Text("Cancel") }
    }
}

// ---------------------------------------------------------------------------------------- Permissions

private class Step(
    val id: String, val icon: ImageVector, val title: String, val why: String,
    val button: String, val info: Info? = null, val action: () -> Unit,
)

private const val RESTRICTED = "If Android says it's restricted, open Mydroid's app info, tap ⋮ and choose Allow restricted settings."

private fun buildSteps(s: UiState, a: Actions): List<Step> {
    val set = s.settings ?: return emptyList()
    val r = s.report
    val watch = Presence.offerWatchProfile(set.notifications)
    return buildList {
        if (set.notifications && r.state(Feature.Notifications) != FeatureState.On) {
            add(Step("notif", Icons.Default.Notifications, "Notifications", "See and reply to notifications on your Mac", "Open notification access",
                action = a.allowNotificationAccess))
        }
        if (set.photos && r.state(Feature.Photos) != FeatureState.On) {
            add(Step("photos", Glyphs.Photo, "Camera roll", "Sync new photos to your Mac", "Allow",
                info = Info("Camera roll", "Choose all photos for automatic sync. You can also share selected photos."), action = a.allowPhotos))
        }
        if (r.supportsCalls && set.calls && r.state(Feature.Calls) != FeatureState.On) {
            add(Step("calls", Icons.Default.Call, "Calls", "See and answer calls on your Mac", "Allow", action = a.allowCalls))
        }
        if (r.supportsTexts && set.smsHistory && r.state(Feature.Sms) != FeatureState.On) {
            add(Step("sms", Icons.Default.Email, "Text from your Mac", "Read and send texts from your Mac", "Allow",
                info = Info("Text from your Mac", "Mydroid reads your texts when your Mac asks."), action = a.allowSmsHistory))
        }
        if (r.presence != PresenceStatus.Unsupported &&
            (r.presence != PresenceStatus.Ready || !r.bluetoothOn || (watch && !r.codesFromApps))) {
            add(Step("presence", Glyphs.Laptop, "Your Mac nearby",
                if (watch) "Save battery and show codes from apps" else "Help your phone reconnect when your Mac is near",
                when {
                    r.presence == PresenceStatus.NeedsPermission -> "Allow Nearby devices"
                    !r.bluetoothOn -> "Turn on Bluetooth"
                    else -> "Choose your Mac"
                },
                info = Info("Your Mac nearby", if (watch) "Android calls your Mac a watch in the approval dialog." else "Keep your Mac awake and nearby."),
                action = a.allowPresence))
        }
        if (r.supportsTexts && set.notifications && r.otp != FeatureState.On) {
            add(Step("otp", Icons.Default.Notifications, "Codes from texts", "Show one-time codes from new texts", "Allow",
                info = Info("Codes from texts", "Mydroid looks for codes in new texts and never stores them."), action = a.allowSms))
        }
        if (r.supportsCalls && set.calls && !r.dial) {
            add(Step("dial", Icons.Default.Call, "Call from your Mac", "Start calls from your Mac", "Allow",
                info = Info("Call from your Mac", "Your phone places the call and carries the audio."), action = a.allowDial))
        }
        if (Build.VERSION.SDK_INT >= 33 && !r.postNotifications) {
            add(Step("alerts", Icons.Default.Info, "Mydroid alerts", "See received files and approve code fills", "Allow", action = a.allowAlerts))
        }
        if (r.backgroundRestricted) {
            add(Step("battery", Glyphs.Battery, "Stay connected", Oem.backgroundHelp, "Open app info", action = a.openAppInfo))
        }
        if (Oem.hasSeparateBackgroundControls && !r.batteryOptimizationExempt) {
            add(Step("idle", Glyphs.Battery, "Sync while your phone is locked", "Allow Mydroid to run while Android is idle.",
                "Allow while idle", info = Info("Battery optimization", "This can increase battery use."), action = a.openBatteryOptimization))
        }
    }
}

@Composable
internal fun PermissionsScreen(s: UiState, a: Actions) {
    var skipped by rememberSaveable { mutableStateOf(emptyArray<String>()) }
    var triedNotificationAccess by rememberSaveable { mutableStateOf(false) }
    val steps = buildSteps(s, a)
    val current = steps.firstOrNull { it.id !in skipped }
    val waiting = s.settings == null
    Column(Modifier.fillMaxSize().safeDrawingPadding().padding(horizontal = 24.dp)) {
        Spacer(Modifier.height(24.dp))
        Text("Paired with ${s.macName}", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
        Spacer(Modifier.height(4.dp))
        Text(
            if (waiting) "One moment…" else if (current == null) "All set" else "Finish setup",
            style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(20.dp))
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            when {
                waiting -> Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(12.dp))
                    Text("Waiting for your Mac…", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                current != null -> {
                    StepCard(current) {
                        if (current.id == "notif") triedNotificationAccess = true
                        current.action()
                    }
                    if (current.id == "notif" && triedNotificationAccess && Build.VERSION.SDK_INT >= 33) {
                        Text("If Android says access is restricted, open App info and tap ⋮ → Allow restricted settings. Then try again.")
                        TextButton(onClick = a.openAppInfo) { Text("Open app info") }
                    }
                }
                steps.isNotEmpty() -> Text("You can finish skipped steps in Settings.")
            }
        }
        if (current != null) {
            TextButton(onClick = { skipped = skipped + current.id }, modifier = Modifier.fillMaxWidth()) { Text("Skip this step") }
            TextButton(onClick = a.finishSetup, modifier = Modifier.fillMaxWidth()) { Text("Finish for now") }
        } else {
            Button(onClick = a.finishSetup, modifier = Modifier.fillMaxWidth().height(56.dp), shape = RoundedCornerShape(18.dp)) {
                Text(if (waiting) "Finish for now" else "Continue")
            }
        }
        Spacer(Modifier.height(16.dp))
    }
}

@Composable
private fun StepCard(st: Step, onClick: () -> Unit) {
    val cs = MaterialTheme.colorScheme
    Card(colors = CardDefaults.cardColors(containerColor = cs.primaryContainer), shape = RoundedCornerShape(24.dp), modifier = Modifier.fillMaxWidth().animateContentSize()) {
        Column(Modifier.padding(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(st.icon, null, tint = cs.onPrimaryContainer)
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text(st.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    Text(st.why, style = MaterialTheme.typography.bodyMedium, color = cs.onPrimaryContainer)
                }
                if (st.info != null) InfoButton(st.info)
            }
            Spacer(Modifier.height(12.dp))
            Button(onClick = onClick, shape = RoundedCornerShape(16.dp)) { Text(st.button) }
        }
    }
}

package com.mydroid.android.ui

import android.text.format.DateUtils
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
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mydroid.android.*
import com.mydroid.android.fix.Oem
import com.mydroid.android.net.Link
import com.mydroid.android.net.UiState
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
    val button: String, val done: Boolean, val info: Info? = null, val optional: Boolean = false, val action: () -> Unit,
)

private const val RESTRICTED = "If Android says it's restricted, open Mydroid's app info, tap ⋮ and choose Allow restricted settings."

@Composable
private fun buildSteps(s: UiState, a: Actions): List<Step> {
    val ctx = LocalContext.current
    val set = s.settings ?: return emptyList()
    val r = s.report
    return buildList {
        if (set.notifications) add(Step("notif", Icons.Default.Notifications, "Notifications", "Reply to messages from your Mac", "Allow", r.state(Feature.Notifications) == FeatureState.On,
            info = Info("Notifications", "Mydroid mirrors your notifications to your Mac so you can reply there. $RESTRICTED"), action = a.allowNotificationAccess))
        if (set.notifications) add(Step("otp", Icons.Default.Notifications, "Verification codes", "Show one-time codes on your Mac", "Allow", r.otp == FeatureState.On,
            info = Info("Verification codes", "Android hides one-time codes from notifications, so Mydroid looks for them in new texts. It never stores them. $RESTRICTED"), action = a.allowSms))
        if (set.photos) add(Step("photos", Glyphs.Photo, "Camera roll", if (r.photosPartial) "Only some photos are shared" else "Sync new photos to your Mac", if (r.photosPartial) "Allow all" else "Allow",
            r.state(Feature.Photos) == FeatureState.On && !r.photosPartial,
            info = Info("Camera roll", "New photos land on your Mac automatically, and you can browse your camera roll there. Choose Allow all so new photos sync."), action = a.allowPhotos))
        if (set.calls) add(Step("calls", Icons.Default.Call, "Calls", "See and answer calls on your Mac", "Allow", r.state(Feature.Calls) == FeatureState.On && !r.callsMissingOptional, action = a.allowCalls))
        if (set.calls) add(Step("dial", Icons.Default.Call, "Call from your Mac", "Start calls from your Mac", "Allow", r.dial,
            info = Info("Call from your Mac", "Your phone places the call. Audio stays on your phone."), action = a.allowDial))
        if (set.smsHistory) add(Step("sms", Icons.Default.Email, "Text from your Mac", "Read and send texts from your Mac", "Allow", r.state(Feature.Sms) == FeatureState.On,
            info = Info("Text from your Mac", "Mydroid reads your texts only when your Mac asks. $RESTRICTED"), action = a.allowSmsHistory))
        if (Build.VERSION.SDK_INT >= 33) add(Step("alerts", Icons.Default.Info, "Alerts", "Hear about problems", "Allow", r.postNotifications, action = a.allowAlerts))
        if (r.presence != PresenceStatus.Unsupported) add(Step("presence", Glyphs.Laptop, "Your Mac nearby",
            when {
                !r.bluetoothOn -> "Turn on Bluetooth first"
                Build.VERSION.SDK_INT >= 33 -> "Saves battery, shows codes from apps"
                else -> "Saves battery"
            },
            if (r.presence == PresenceStatus.NeedsPermission) "Allow Bluetooth" else "Choose your Mac",
            r.presence == PresenceStatus.Ready && (r.codesFromApps || Build.VERSION.SDK_INT < 33),
            info = Info(
                "Your Mac nearby",
                "Mydroid listens for your Mac's Bluetooth signal, never your location. Keep your Mac awake and nearby, then pick it." +
                    if (Build.VERSION.SDK_INT >= 33) " Android's dialog calls it a “watch”; that's what lets codes from apps through." else "",
            ), action = a.allowPresence))
        add(Step("battery", Glyphs.Battery, "Stay connected", "Keep working with the screen off", "Allow", !r.backgroundRestricted, action = a.allowBattery))
        // Android can't read OEM auto-start switches, so only ask when there's evidence the OEM
        // actually closed Mydroid since the user last looked. Otherwise it's an optional tip.
        if (!r.backgroundRestricted && Oem.autoStartIntent(ctx) != null) {
            val killedAt = remember(s.oemOpenedAt) { Oem.needsAutoStart(ctx, s.oemOpenedAt) }
            if (killedAt != null) {
                add(Step("oem", Icons.Default.Settings, "Allow auto-start",
                    "${Oem.brandName} closed Mydroid ${DateUtils.getRelativeTimeSpanString(killedAt)}",
                    "Open settings", done = false, info = Info("Auto-start", "Turn Mydroid on in the ${Oem.brandName} auto-launch list so it stays connected."), action = a.openOem))
            } else if (s.oemOpenedAt == 0L) {
                add(Step("oem", Icons.Default.Settings, "Auto-start", "Optional",
                    "Open settings", done = false, optional = true,
                    info = Info("Auto-start", "Some ${Oem.brandName} phones close background apps anyway. Android can't check this setting, so Mydroid only asks again if it gets closed."), action = a.openOem))
            }
        }
    }
}

@Composable
internal fun PermissionsScreen(s: UiState, a: Actions) {
    val steps = buildSteps(s, a)
    val current = steps.firstOrNull { !it.done && !it.optional }
    Column(Modifier.fillMaxSize().safeDrawingPadding().padding(horizontal = 24.dp)) {
        Spacer(Modifier.height(24.dp))
        Text("Paired with ${s.macName}", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
        Spacer(Modifier.height(4.dp))
        Text(
            if (s.settings == null) "One moment…" else if (current == null) "All set" else "Finish setup",
            style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(20.dp))
        if (s.settings == null) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                Spacer(Modifier.width(12.dp))
                Text("Waiting for your Mac…", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            steps.forEach { st -> StepCard(st, isCurrent = st === current) }
            Spacer(Modifier.height(8.dp))
        }
        Button(onClick = a.finishSetup, modifier = Modifier.fillMaxWidth().height(56.dp).padding(bottom = 0.dp), shape = RoundedCornerShape(18.dp),
            colors = if (current == null) ButtonDefaults.buttonColors() else ButtonDefaults.filledTonalButtonColors()) {
            Text(if (current == null) "Continue" else "Not now")
        }
        Spacer(Modifier.height(16.dp))
    }
}

@Composable
private fun StepCard(st: Step, isCurrent: Boolean) {
    val cs = MaterialTheme.colorScheme
    // Done steps collapse to a ✓ row; the current one gets the button; later ones wait, dimmed.
    if (st.done) {
        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(horizontal = 18.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.CheckCircle, "Done", Modifier.size(22.dp), tint = cs.primary)
            Spacer(Modifier.width(14.dp))
            Text(st.title, style = MaterialTheme.typography.titleMedium, color = cs.onSurfaceVariant)
        }
        return
    }
    val container by animateColorAsState(if (isCurrent) cs.primaryContainer else cs.surfaceContainerLow, label = "c")
    Card(colors = CardDefaults.cardColors(containerColor = container), shape = RoundedCornerShape(24.dp), modifier = Modifier.fillMaxWidth().animateContentSize().alpha(if (isCurrent) 1f else 0.7f)) {
        Column(Modifier.padding(start = 18.dp, top = 14.dp, bottom = 14.dp, end = if (st.info != null) 6.dp else 18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(st.icon, null, tint = if (isCurrent) cs.onPrimaryContainer else cs.primary)
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text(st.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    Text(st.why, style = MaterialTheme.typography.bodyMedium, color = if (isCurrent) cs.onPrimaryContainer else cs.onSurfaceVariant)
                }
                if (st.info != null) InfoButton(st.info)
            }
            if (isCurrent || st.optional) {
                Spacer(Modifier.height(12.dp))
                Box(Modifier.padding(end = if (st.info != null) 12.dp else 0.dp)) {
                    if (st.optional) OutlinedButton(onClick = st.action, shape = RoundedCornerShape(16.dp)) { Text(st.button) }
                    else Button(onClick = st.action, shape = RoundedCornerShape(16.dp)) { Text(st.button) }
                }
            }
        }
    }
}

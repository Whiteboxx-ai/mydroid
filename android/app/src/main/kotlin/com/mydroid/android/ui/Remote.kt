package com.mydroid.android.ui

import android.os.SystemClock
import android.view.HapticFeedbackConstants
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.mydroid.android.net.Link
import com.mydroid.android.net.UiState
import com.mydroid.android.remote.LaserPointer
import com.mydroid.android.remote.LaserSensor
import com.mydroid.android.remote.RemoteApi
import com.mydroid.protocol.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date

internal enum class RemoteMode(val label: String) { Trackpad("Trackpad"), Presenter("Presenter"), Media("Media") }

private enum class Block { Away, Allow }

// ---------------------------------------------------------------------------------------- screen

/**
 * Full-screen remote for the Mac (PROTOCOL.md 10): Trackpad, Presenter and Media. [now] is fixed in tests and screenshots;
 * live, it ticks once a second while the screen is visible. [timerStart] is when the presentation timer began.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun RemoteScreen(
    s: UiState, api: RemoteApi, mode: RemoteMode, onMode: (RemoteMode) -> Unit, onBack: () -> Unit,
    timerStart: Long, onTimerReset: () -> Unit, now: Long? = null,
) {
    val cs = MaterialTheme.colorScheme
    val connected = s.link == Link.Connected
    val accessibility = s.mac.remote?.accessibility
    val block = when {
        !connected -> Block.Away
        accessibility == false -> Block.Allow
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

    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Top + WindowInsetsSides.Horizontal)).padding(start = 6.dp, end = 20.dp, top = 8.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onBack, Modifier.size(48.dp).semantics { contentDescription = "Back" }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, null) }
            Spacer(Modifier.width(6.dp))
            Column(Modifier.weight(1f)) {
                Text("Remote", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
                Text(
                    if (connected) "Controlling ${s.macName.replaceFirstChar { it.uppercase() }}" else "Waiting for ${s.macName.replaceFirstChar { it.uppercase() }}",
                    style = MaterialTheme.typography.bodySmall, color = cs.onSurfaceVariant, maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                )
            }
        }
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp)) {
            RemoteMode.entries.forEachIndexed { i, m ->
                SegmentedButton(
                    selected = m == mode, onClick = { onMode(m) },
                    shape = SegmentedButtonDefaults.itemShape(i, RemoteMode.entries.size),
                    icon = {}, modifier = Modifier.heightIn(min = 48.dp),
                ) { Text(m.label, maxLines = 1) }
            }
        }
        Box(Modifier.weight(1f).fillMaxWidth()) {
            val bottom = Modifier.windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom))
            when (mode) {
                RemoteMode.Trackpad -> TrackpadPane(api, input, bottom)
                RemoteMode.Presenter -> PresenterPane(s, api, timerStart, onTimerReset, now, bottom)
                RemoteMode.Media -> MediaPane(input, bottom)
            }
            if (block != null) BlockOverlay(block, s.macName)
        }
    }
}

/** Calm, not alarming: says what is needed, and clears itself the moment `remote.state` flips. */
@Composable
private fun BlockOverlay(block: Block, macName: String) {
    val cs = MaterialTheme.colorScheme
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
                    if (block == Block.Allow) "A prompt is waiting there" else "Remote works when it's back",
                    style = MaterialTheme.typography.bodyMedium, color = cs.onSurfaceVariant, textAlign = TextAlign.Center,
                )
                if (block == Block.Allow) {
                    Spacer(Modifier.height(6.dp))
                    CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.5.dp)
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------------------- trackpad

@OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
private fun TrackpadPane(api: RemoteApi, input: RemoteInput, insets: Modifier) {
    val cs = MaterialTheme.colorScheme
    val view = LocalView.current
    val density = LocalDensity.current.density
    val wake = remember { Channel<Unit>(Channel.CONFLATED) }
    val engine = remember(api) {
        TrackpadEngine(RemoteSender(api::send), haptic = { view.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK) }, wake = { wake.trySend(Unit) })
    }
    // A frame loop only while there is something to do (a hold may start, movement is waiting, momentum is running).
    LaunchedEffect(engine) {
        for (u in wake) while (engine.active) { delay(8); engine.tick(SystemClock.uptimeMillis()) }
    }
    LifecycleEventEffect(Lifecycle.Event.ON_PAUSE) { engine.cancel(SystemClock.uptimeMillis()) }
    DisposableEffect(engine) { onDispose { engine.cancel(SystemClock.uptimeMillis()) } }

    var cmd by remember(input) { mutableStateOf(input.cmdArmed) }
    remember(input) { input.onCmdChanged { cmd = it } }

    var keyboard by rememberSaveable { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().then(insets).padding(horizontal = 20.dp).padding(bottom = 12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Surface(
            Modifier.weight(1f).fillMaxWidth()
                .semantics { contentDescription = "Trackpad. Drag to move the cursor, tap to click, two fingers to scroll." }
                .pointerInput(engine) {
                    awaitPointerEventScope {
                        while (true) {
                            val e = awaitPointerEvent()
                            val fingers = e.changes.filter { it.pressed }.map { Finger(it.id.value, it.position.x / density.toDouble(), it.position.y / density.toDouble()) }
                            engine.touch(e.changes.maxOf { it.uptimeMillis }, fingers)
                            e.changes.forEach { it.consume() }
                        }
                    }
                },
            shape = RoundedCornerShape(28.dp), color = cs.surfaceContainerLow, border = BorderStroke(1.dp, cs.outlineVariant.copy(alpha = 0.6f)),
        ) {
            Box(contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Icon(Glyphs.Mouse, null, Modifier.size(36.dp), tint = cs.onSurfaceVariant.copy(alpha = 0.5f))
                    Text("Two fingers to scroll · hold to drag", style = MaterialTheme.typography.bodyMedium, color = cs.onSurfaceVariant, textAlign = TextAlign.Center)
                }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilledIconToggleButton(
                checked = keyboard, onCheckedChange = { keyboard = it },
                modifier = Modifier.size(52.dp).semantics { contentDescription = if (keyboard) "Close keyboard" else "Open keyboard" },
            ) { Icon(Glyphs.Keyboard, null, Modifier.size(26.dp)) }
            Row(Modifier.weight(1f).horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                KeyChip("esc") { input.key("escape") }
                KeyChip("tab") { input.key("tab") }
                KeyChip("←", "Left arrow") { input.key("left") }
                KeyChip("↑", "Up arrow") { input.key("up") }
                KeyChip("↓", "Down arrow") { input.key("down") }
                KeyChip("→", "Right arrow") { input.key("right") }
                KeyChip("⌘", "Command, applies to the next key", selected = cmd) { input.setCmd(!cmd) }
                KeyChip("⌘C", "Copy") { input.shortcut("c", setOf("cmd")) }
                KeyChip("⌘V", "Paste") { input.shortcut("v", setOf("cmd")) }
                KeyChip("⌘Tab", "Switch app") { input.shortcut("tab", setOf("cmd")) }
                KeyChip("Mission Control") { input.shortcut("up", setOf("ctrl")) }
            }
        }
        if (keyboard) KeyboardCapture(input, onClosed = { keyboard = false })
    }
}

/** A tiny hidden text field whose only job is to bring up Android's keyboard; every change goes to the Mac as typing. */
@OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
private fun KeyboardCapture(input: RemoteInput, onClosed: () -> Unit) {
    val diff = remember { KeyboardDiff() }
    var field by remember { mutableStateOf(TextFieldValue(diff.fieldText, TextRange(diff.fieldText.length))) }
    val focus = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current
    val focusManager = LocalFocusManager.current
    val imeVisible = WindowInsets.isImeVisible
    var seen by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() }; keyboard?.show() }
    // The user dismissed the keyboard (back gesture): the button should go back to "closed".
    LaunchedEffect(imeVisible) { if (imeVisible) seen = true else if (seen) onClosed() }
    DisposableEffect(Unit) { onDispose { keyboard?.hide(); focusManager.clearFocus() } }
    BasicTextField(
        value = field,
        onValueChange = { nv ->
            input.ops(diff.onChange(nv.text))
            // Keep the IME's own composition while it is just typing; only put the sentinel back when it was eaten.
            field = if (nv.text == diff.fieldText) nv else TextFieldValue(diff.fieldText, TextRange(diff.fieldText.length))
        },
        modifier = Modifier.size(1.dp).focusRequester(focus),
        singleLine = true,
        textStyle = TextStyle(color = Color.Transparent),
        cursorBrush = SolidColor(Color.Transparent),
        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false, imeAction = ImeAction.Send),
        keyboardActions = KeyboardActions(onSend = { input.key("enter") }),
    )
}

@Composable
private fun KeyChip(label: String, description: String = label, selected: Boolean = false, onClick: () -> Unit) {
    val cs = MaterialTheme.colorScheme
    val view = LocalView.current
    Surface(
        onClick = { view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP); onClick() },
        shape = RoundedCornerShape(16.dp),
        color = if (selected) cs.primary else cs.surfaceContainerHighest,
        contentColor = if (selected) cs.onPrimary else cs.onSurface,
        modifier = Modifier.semantics { contentDescription = description; role = Role.Button },
    ) {
        Box(Modifier.heightIn(min = 48.dp).widthIn(min = 48.dp).padding(horizontal = 14.dp), contentAlignment = Alignment.Center) {
            Text(label, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, maxLines = 1)
        }
    }
}

// ---------------------------------------------------------------------------------------- presenter

@Composable
private fun PresenterPane(s: UiState, api: RemoteApi, timerStart: Long, onTimerReset: () -> Unit, fixedNow: Long?, insets: Modifier) {
    val cs = MaterialTheme.colorScheme
    val ctx = LocalContext.current
    val view = LocalView.current
    val clock = fixedNow ?: rememberSecondClock()
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

    Column(Modifier.fillMaxSize().then(insets).padding(horizontal = 20.dp).padding(bottom = 12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        val presenting = s.mac.remote?.presenting
        if (presenting != null) {
            Surface(shape = RoundedCornerShape(50), color = cs.tertiaryContainer, contentColor = cs.onTertiaryContainer) {
                Row(Modifier.padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Glyphs.Slideshow, null, Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(if (presenting.app.isBlank()) "Presenting on your Mac" else "Presenting in ${presenting.app}", style = MaterialTheme.typography.labelLarge)
                }
            }
        }
        Surface(
            onClick = onTimerReset, shape = RoundedCornerShape(24.dp), color = cs.surfaceContainerLow,
            modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Elapsed ${formatElapsed(clock - timerStart)}. Tap to reset." },
        ) {
            Row(Modifier.padding(horizontal = 20.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Elapsed", style = MaterialTheme.typography.labelMedium, color = cs.onSurfaceVariant)
                    Text(formatElapsed(clock - timerStart), style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.SemiBold)
                    Text("Tap to reset", style = MaterialTheme.typography.labelSmall, color = cs.onSurfaceVariant)
                }
                Column(horizontalAlignment = Alignment.End) {
                    Text("Now", style = MaterialTheme.typography.labelMedium, color = cs.onSurfaceVariant)
                    Text(DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(clock)), style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Medium)
                }
            }
        }
        Row(Modifier.weight(1f).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            PressButton(
                { go(false) }, Modifier.weight(1f).fillMaxHeight(), cs.secondaryContainer, cs.onSecondaryContainer, RoundedCornerShape(32.dp), "Back one slide",
            ) { BigLabel(Glyphs.ArrowLeft, "Back") }
            PressButton(
                { go(true) }, Modifier.weight(1.5f).fillMaxHeight(), cs.primary, cs.onPrimary, RoundedCornerShape(32.dp), "Next slide",
            ) { BigLabel(Glyphs.ArrowRight, "Next") }
        }
        val red = Color(0xFFD93025)
        PressButton(
            onPress = {}, modifier = Modifier.fillMaxWidth().height(84.dp),
            container = if (lasering) red else cs.tertiaryContainer, content = if (lasering) Color.White else cs.onTertiaryContainer,
            shape = RoundedCornerShape(28.dp), description = "Laser pointer. Hold, then move your phone.",
            custom = { pressed ->
                if (!laserOk) return@PressButton
                if (pressed) { lasering = true; laser.press() } else { lasering = false; laser.release() }
            },
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.Center) {
                Icon(Glyphs.Target, null, Modifier.size(30.dp))
                Spacer(Modifier.width(14.dp))
                Column {
                    Text(
                        when {
                            !laserOk -> "No motion sensor"
                            lasering -> "Pointing…"
                            else -> "Hold for laser pointer"
                        },
                        style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold,
                    )
                    if (laserOk && lasering) Text("Move your phone to aim", style = MaterialTheme.typography.bodySmall)
                }
            }
        }
        Text(
            "Volume buttons change slides", Modifier.fillMaxWidth(),
            style = MaterialTheme.typography.bodySmall, color = cs.onSurfaceVariant, textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun BigLabel(icon: ImageVector, label: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Icon(icon, null, Modifier.size(56.dp))
        Text(label, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
    }
}

internal fun formatElapsed(ms: Long): String {
    val total = (ms / 1000).coerceAtLeast(0)
    val h = total / 3600; val m = total / 60 % 60; val sec = total % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, sec) else "%02d:%02d".format(m, sec)
}

/** Wall clock, once a second, only while the screen is showing. */
@Composable
private fun rememberSecondClock(): Long {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    val owner = LocalLifecycleOwner.current
    LaunchedEffect(owner) {
        owner.lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) { now = System.currentTimeMillis(); delay(1000 - now % 1000) }
        }
    }
    return now
}

// ---------------------------------------------------------------------------------------- media

@Composable
private fun MediaPane(input: RemoteInput, insets: Modifier) {
    val cs = MaterialTheme.colorScheme
    Column(
        Modifier.fillMaxSize().then(insets).padding(horizontal = 20.dp).padding(bottom = 12.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp, Alignment.CenterVertically), horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("Plays on your Mac", style = MaterialTheme.typography.bodyMedium, color = cs.onSurfaceVariant)
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
            PressButton({ input.media("prev") }, Modifier.size(72.dp), cs.secondaryContainer, cs.onSecondaryContainer, CircleShape, "Previous track") {
                Icon(Glyphs.SkipPrevious, null, Modifier.size(34.dp))
            }
            PressButton({ input.media("playpause") }, Modifier.size(120.dp), cs.primary, cs.onPrimary, CircleShape, "Play or pause") {
                Row(horizontalArrangement = Arrangement.spacedBy(2.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Glyphs.Play, null, Modifier.size(36.dp)); Icon(Glyphs.Pause, null, Modifier.size(36.dp))
                }
            }
            PressButton({ input.media("next") }, Modifier.size(72.dp), cs.secondaryContainer, cs.onSecondaryContainer, CircleShape, "Next track") {
                Icon(Glyphs.SkipNext, null, Modifier.size(40.dp))
            }
        }
        Spacer(Modifier.height(8.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            PressButton({ input.media("voldown") }, Modifier.weight(1f).height(88.dp), cs.surfaceContainerHighest, cs.onSurface, RoundedCornerShape(28.dp), "Volume down", repeat = true) {
                Icon(Glyphs.VolumeDown, null, Modifier.size(34.dp))
            }
            PressButton({ input.media("mute") }, Modifier.weight(1f).height(88.dp), cs.surfaceContainerHighest, cs.onSurface, RoundedCornerShape(28.dp), "Mute") {
                Icon(Glyphs.VolumeOff, null, Modifier.size(34.dp))
            }
            PressButton({ input.media("volup") }, Modifier.weight(1f).height(88.dp), cs.surfaceContainerHighest, cs.onSurface, RoundedCornerShape(28.dp), "Volume up", repeat = true) {
                Icon(Glyphs.VolumeUp, null, Modifier.size(34.dp))
            }
        }
    }
}

// ---------------------------------------------------------------------------------------- buttons

/**
 * A big button that acts the moment the finger lands (a clicker that waits for you to lift is a clicker that feels late).
 * [repeat] keeps firing while held (volume). [custom] replaces the press action with press/release callbacks (the laser).
 */
@Composable
private fun PressButton(
    onPress: () -> Unit, modifier: Modifier, container: Color, content: Color, shape: Shape, description: String,
    repeat: Boolean = false, custom: ((pressed: Boolean) -> Unit)? = null, body: @Composable BoxScope.() -> Unit,
) {
    val view = LocalView.current
    var pressed by remember { mutableStateOf(false) }
    // Callbacks change on every recomposition; the gesture must not restart (and release the laser) because of that.
    val press by rememberUpdatedState(onPress)
    val customPress by rememberUpdatedState(custom)
    val scale by animateFloatAsState(if (pressed) 0.95f else 1f, label = "press")
    Box(
        modifier.scale(scale).clip(shape).background(if (pressed) container.copy(alpha = 0.82f) else container)
            .semantics(mergeDescendants = true) {
                role = Role.Button; contentDescription = description
                onClick(label = description) { press(); true }
            }
            .pointerInput(repeat, custom != null) {
                detectTapGestures(onPress = {
                    pressed = true
                    view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                    try {
                        val c = customPress
                        if (c != null) { c(true); tryAwaitRelease() }
                        else if (repeat) coroutineScope {
                            press()
                            val job = launch { delay(450); while (true) { press(); delay(110) } }
                            tryAwaitRelease(); job.cancel()
                        } else { press(); tryAwaitRelease() }
                    } finally {
                        pressed = false
                        customPress?.invoke(false)
                    }
                })
            },
        contentAlignment = Alignment.Center,
    ) {
        CompositionLocalProvider(LocalContentColor provides content) { body() }
    }
}

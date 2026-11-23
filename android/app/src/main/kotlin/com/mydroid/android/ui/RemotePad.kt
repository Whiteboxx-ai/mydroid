package com.mydroid.android.ui

import android.os.SystemClock
import android.view.HapticFeedbackConstants
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import com.mydroid.android.remote.PadSettings
import com.mydroid.android.remote.RemoteApi
import com.mydroid.android.remote.rememberPadSettings
import com.mydroid.protocol.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

// ---------------------------------------------------------------------------------------- the pad

/**
 * The pad: the whole surface is a trackpad, the right edge is a scroll strip, the bottom bar holds the two buttons,
 * and a row of chips below does the things people reach for most. Typing swaps the chips for what is being typed.
 */
@Composable
internal fun PadPane(api: RemoteApi, input: RemoteInput, typing: Boolean, onTyping: (Boolean) -> Unit, insets: Modifier, settings: PadSettings = rememberPadSettings()) {
    val cs = MaterialTheme.colorScheme
    val view = LocalView.current
    val density = LocalDensity.current.density
    val wake = remember { Channel<Unit>(Channel.CONFLATED) }
    val engine = remember(api, settings.speed, settings.reverseScroll, settings.tapToClick) {
        TrackpadEngine(RemoteSender(api::send), settings.config(), haptic = { view.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK) }, wake = { wake.trySend(Unit) })
    }
    // A frame loop only while there is something to do (a hold may start, movement is waiting, momentum is running).
    LaunchedEffect(engine) { for (u in wake) while (engine.active) { delay(8); engine.tick(SystemClock.uptimeMillis()) } }
    LifecycleEventEffect(Lifecycle.Event.ON_PAUSE) { engine.cancel(SystemClock.uptimeMillis()) }
    DisposableEffect(engine) { onDispose { engine.cancel(SystemClock.uptimeMillis()) } }

    Column(Modifier.fillMaxSize().then(insets).padding(horizontal = 16.dp).padding(bottom = 12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Box(
            Modifier.weight(1f).fillMaxWidth().clip(RoundedCornerShape(28.dp)).background(cs.surfaceContainerLow)
                .dotGrid(cs.primary.copy(alpha = 0.16f)),
        ) {
            // The touch area is everything but the strip and the buttons, so those can have touches of their own.
            Box(
                Modifier.fillMaxSize().padding(end = STRIP_WIDTH, bottom = BAR_HEIGHT)
                    .semantics { contentDescription = "Trackpad. Drag to move the cursor, tap to click, two fingers to scroll, three fingers to swipe between desktops." }
                    .pointerInput(engine) {
                        awaitPointerEventScope {
                            while (true) {
                                val e = awaitPointerEvent()
                                val fingers = e.changes.filter { it.pressed }.map { Finger(it.id.value, it.position.x / density.toDouble(), it.position.y / density.toDouble()) }
                                engine.touch(e.changes.maxOf { it.uptimeMillis }, fingers)
                                if (fingers.isEmpty() && !settings.hintsSeen) settings.updateHintsSeen(true)
                                e.changes.forEach { it.consume() }
                            }
                        }
                    },
                contentAlignment = Alignment.Center,
            ) {
                val tipsAlpha by androidx.compose.animation.core.animateFloatAsState(if (!settings.hintsSeen && !typing) 1f else 0f, label = "tips")
                if (tipsAlpha > 0.01f) Box(Modifier.alpha(tipsAlpha)) { GestureTips() }
                if (typing) Text("The pad still works", style = MaterialTheme.typography.bodyMedium, color = cs.onSurfaceVariant)
            }
            ScrollStrip(api, settings, Modifier.align(Alignment.CenterEnd).padding(bottom = BAR_HEIGHT).width(STRIP_WIDTH).fillMaxHeight())
            ClickBar(RemoteSender(api::send), Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(BAR_HEIGHT))
        }
        if (typing) TypingControls(input) else QuickRow(input, onKeyboard = { onTyping(true) })
        if (typing) KeyboardCapture(input, onClosed = { onTyping(false) })
    }
}

private val STRIP_WIDTH = 48.dp
private val BAR_HEIGHT = 60.dp

/** A faint dot grid, so the surface reads as something to touch and movement has something to slide against. */
private fun Modifier.dotGrid(color: Color): Modifier = drawBehind {
    val step = 24.dp.toPx()
    var y = step / 2
    while (y < size.height) {
        var x = step / 2
        while (x < size.width) { drawCircle(color, radius = 1.3.dp.toPx(), center = Offset(x, y)); x += step }
        y += step
    }
}

@Composable
private fun GestureTips() {
    val cs = MaterialTheme.colorScheme
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Tip(1, "Tap", "Click")
        Tip(2, "Two fingers", "Scroll · tap for right-click")
        Tip(3, "Three fingers", "Swipe between desktops")
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(40.dp).clip(CircleShape).background(cs.surface), contentAlignment = Alignment.Center) { Icon(Glyphs.ArrowRight, null, Modifier.size(20.dp), tint = cs.primary) }
            Column { Text("Hold, then move", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold); Text("Drag", style = MaterialTheme.typography.bodyMedium, color = cs.onSurfaceVariant) }
        }
    }
}

@Composable
private fun Tip(fingers: Int, title: String, sub: String) {
    val cs = MaterialTheme.colorScheme
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(40.dp).clip(CircleShape).background(cs.surface), contentAlignment = Alignment.Center) {
            Row(horizontalArrangement = Arrangement.spacedBy(3.dp)) { repeat(fingers) { Box(Modifier.size(if (fingers == 1) 10.dp else 7.dp).clip(CircleShape).background(cs.primary)) } }
        }
        Column { Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold); Text(sub, style = MaterialTheme.typography.bodyMedium, color = cs.onSurfaceVariant) }
    }
}

/** Drag up and down to scroll: the same as two fingers, for people who want one thumb. */
@Composable
private fun ScrollStrip(api: RemoteApi, settings: PadSettings, modifier: Modifier) {
    val cs = MaterialTheme.colorScheme
    val density = LocalDensity.current
    val gain = 2.5 * (if (settings.reverseScroll) -1 else 1)
    var offsetPx by remember { mutableFloatStateOf(0f) }
    var pending by remember { mutableFloatStateOf(0f) }
    var lastSent by remember { mutableLongStateOf(0L) }
    var began by remember { mutableStateOf(false) }
    val tick = with(density) { 18.dp.toPx() }
    Box(
        modifier.background(cs.primary.copy(alpha = 0.05f))
            .semantics { contentDescription = "Scroll strip. Drag up or down to scroll." }
            .pointerInput(gain) {
                detectVerticalDragGestures(
                    onDragStart = { began = false; pending = 0f },
                    onDragEnd = { api.send(RemoteWire.scroll(0.0, pending * gain / density.density, "ended")); pending = 0f; began = false },
                    onDragCancel = { api.send(RemoteWire.scroll(0.0, 0.0, "ended")); pending = 0f; began = false },
                ) { change, dy ->
                    change.consume()
                    offsetPx += dy; pending += dy
                    val now = SystemClock.uptimeMillis()
                    if (now - lastSent >= 17) {
                        api.send(RemoteWire.scroll(0.0, pending * gain / density.density, if (!began) "began" else "changed"))
                        began = true; pending = 0f; lastSent = now
                    }
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        val line = cs.outlineVariant
        val grip = cs.onSurfaceVariant
        Canvas(Modifier.fillMaxSize()) {
            // Ticks that slide with the finger.
            val x = size.width / 2
            var y = ((offsetPx % tick) + tick) % tick
            while (y < size.height) {
                drawLine(line, Offset(x - 7.dp.toPx(), y), Offset(x + 7.dp.toPx(), y), strokeWidth = 2.dp.toPx())
                y += tick
            }
            drawLine(line, Offset(0f, 0f), Offset(0f, size.height), strokeWidth = 1.dp.toPx())
        }
        Icon(Glyphs.ArrowUp, null, Modifier.align(Alignment.TopCenter).padding(top = 10.dp).size(18.dp), tint = grip)
        Icon(Glyphs.ArrowDown, null, Modifier.align(Alignment.BottomCenter).padding(bottom = 10.dp).size(18.dp), tint = grip)
    }
}

/** Two real buttons. A quick press is a click; hold a bit longer and it stays down, so it drags. */
@Composable
private fun ClickBar(out: RemoteSender, modifier: Modifier) {
    val cs = MaterialTheme.colorScheme
    Row(modifier.background(cs.surface.copy(alpha = 0.55f))) {
        ClickHalf("Left click", "left", out, Modifier.weight(1f).fillMaxHeight())
        Box(Modifier.width(1.dp).fillMaxHeight().padding(vertical = 12.dp).background(cs.outlineVariant))
        ClickHalf("Right click", "right", out, Modifier.weight(1f).fillMaxHeight())
    }
}

@Composable
private fun ClickHalf(label: String, button: String, out: RemoteSender, modifier: Modifier) {
    val cs = MaterialTheme.colorScheme
    val view = LocalView.current
    var pressed by remember { mutableStateOf(false) }
    Box(
        modifier.background(if (pressed) cs.primary.copy(alpha = 0.12f) else Color.Transparent)
            .semantics { contentDescription = label; role = Role.Button }
            .pointerInput(button) {
                detectTapGestures(onPress = {
                    pressed = true
                    view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                    var held = false
                    kotlinx.coroutines.coroutineScope {
                        val job = launch { delay(350); held = true; out.down(button) }
                        tryAwaitRelease()
                        job.cancel()
                    }
                    if (held) out.up(button) else out.click(button, 1)
                    pressed = false
                })
            },
        contentAlignment = Alignment.Center,
    ) { Text(label, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Medium, color = cs.onSurfaceVariant) }
}

// ---------------------------------------------------------------------------------------- quick keys and typing

@Composable
private fun QuickRow(input: RemoteInput, onKeyboard: () -> Unit) {
    val cs = MaterialTheme.colorScheme
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        FilledTonalIconButton(
            onClick = onKeyboard, modifier = Modifier.size(52.dp).semantics { contentDescription = "Open keyboard" },
            colors = IconButtonDefaults.filledTonalIconButtonColors(containerColor = cs.primaryContainer, contentColor = cs.onPrimaryContainer),
        ) { Icon(Glyphs.Keyboard, null, Modifier.size(26.dp)) }
        Row(Modifier.weight(1f).horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            KeyChip("Spotlight", "Spotlight search") { input.shortcut("space", setOf("cmd")) }
            KeyChip("Apps", "Switch app") { input.shortcut("tab", setOf("cmd")) }
            KeyChip("Mission Control") { input.shortcut("up", setOf("ctrl")) }
            KeyChip("Copy") { input.shortcut("c", setOf("cmd")) }
            KeyChip("Paste") { input.shortcut("v", setOf("cmd")) }
            KeyChip("Screenshot", "Screenshot tools") { input.shortcut("5", setOf("cmd", "shift")) }
        }
    }
}

@Composable
private fun TypingControls(input: RemoteInput) {
    val cs = MaterialTheme.colorScheme
    var typed by remember(input) { mutableStateOf(input.typed) }
    var armed by remember(input) { mutableStateOf(input.armed) }
    remember(input) { input.onTyped { typed = it }; input.onArmedChanged { armed = it } }
    Surface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(20.dp), color = cs.surfaceContainerHigh) {
        Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
            Text("TYPING ON YOUR MAC", style = MaterialTheme.typography.labelSmall, color = cs.onSurfaceVariant)
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 2.dp).heightIn(min = 28.dp)) {
                Text(typed.takeLast(40), style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Clip)
                Box(Modifier.padding(start = 2.dp).width(2.dp).height(22.dp).clip(RoundedCornerShape(1.dp)).background(cs.primary))
            }
        }
    }
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        KeyChip("esc") { input.key("escape") }
        KeyChip("tab") { input.key("tab") }
        KeyChip("⌘", "Command, applies to the next key", selected = "cmd" in armed) { input.toggle("cmd") }
        KeyChip("⌥", "Option, applies to the next key", selected = "option" in armed) { input.toggle("option") }
        KeyChip("⌃", "Control, applies to the next key", selected = "ctrl" in armed) { input.toggle("ctrl") }
        KeyChip("←", "Left arrow") { input.key("left") }
        KeyChip("↑", "Up arrow") { input.key("up") }
        KeyChip("↓", "Down arrow") { input.key("down") }
        KeyChip("→", "Right arrow") { input.key("right") }
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
    // The user dismissed the keyboard (back gesture): leave typing mode.
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

// ---------------------------------------------------------------------------------------- pad settings

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun PadSettingsSheet(settings: PadSettings, onDismiss: () -> Unit) {
    val cs = MaterialTheme.colorScheme
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = cs.surfaceContainerLow) {
        Column(Modifier.padding(horizontal = 24.dp).padding(bottom = 28.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Pad settings", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(8.dp))
            Text("Pointer speed", style = MaterialTheme.typography.titleSmall)
            Slider(
                value = settings.speed, onValueChange = { settings.updateSpeed(it) },
                valueRange = PadSettings.MIN_SPEED..PadSettings.MAX_SPEED, steps = 5,
                modifier = Modifier.semantics { contentDescription = "Pointer speed" },
            )
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text("Slower", style = MaterialTheme.typography.labelMedium, color = cs.onSurfaceVariant)
                Text("Faster", style = MaterialTheme.typography.labelMedium, color = cs.onSurfaceVariant)
            }
            SwitchRow("Tap to click", "Tapping the pad clicks. The buttons below always work.", settings.tapToClick, settings::updateTapToClick)
            SwitchRow("Reverse scroll", "Flips two-finger and edge scrolling.", settings.reverseScroll, settings::updateReverseScroll)
            TextButton({ settings.updateHintsSeen(false); onDismiss() }) { Text("Show gesture tips again") }
        }
    }
}

@Composable
private fun SwitchRow(title: String, sub: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    val cs = MaterialTheme.colorScheme
    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleSmall)
            Text(sub, style = MaterialTheme.typography.bodySmall, color = cs.onSurfaceVariant)
        }
        Switch(checked, onChange)
    }
}

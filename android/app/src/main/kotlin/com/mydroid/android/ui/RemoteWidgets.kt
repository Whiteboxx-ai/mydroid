package com.mydroid.android.ui

import android.view.HapticFeedbackConstants
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.mydroid.android.net.UiState
import com.mydroid.android.remote.LaserPointer
import com.mydroid.android.remote.LaserSensor
import com.mydroid.android.remote.RemoteApi
import com.mydroid.protocol.*
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date

// Small pieces shared by the Remote tabs.

@Composable
internal fun BigLabel(icon: ImageVector, label: String) {
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
internal fun rememberSecondClock(): Long {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    val owner = LocalLifecycleOwner.current
    LaunchedEffect(owner) {
        owner.lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) { now = System.currentTimeMillis(); delay(1000 - now % 1000) }
        }
    }
    return now
}


@Composable
internal fun KeyChip(label: String, description: String = label, selected: Boolean = false, onClick: () -> Unit) {
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


// ---------------------------------------------------------------------------------------- buttons

/**
 * A big button that acts the moment the finger lands (a clicker that waits for you to lift is a clicker that feels late).
 * [repeat] keeps firing while held (volume). [custom] replaces the press action with press/release callbacks (the laser).
 */
@Composable
internal fun PressButton(
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

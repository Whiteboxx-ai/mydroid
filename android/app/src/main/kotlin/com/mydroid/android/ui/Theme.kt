package com.mydroid.android.ui

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext

private val Light = lightColorScheme(
    primary = Color(0xFF0B6E63), onPrimary = Color.White,
    primaryContainer = Color(0xFFB7F0E4), onPrimaryContainer = Color(0xFF00201C),
    secondaryContainer = Color(0xFFCCE8E2), onSecondaryContainer = Color(0xFF05201C),
    tertiary = Color(0xFF4A6580), tertiaryContainer = Color(0xFFD3E4F8), onTertiaryContainer = Color(0xFF0B1D2D),
    surface = Color(0xFFF6FAF8), background = Color(0xFFF6FAF8),
    surfaceContainerLowest = Color(0xFFFFFFFF), surfaceContainerLow = Color(0xFFEDF3F1), surfaceContainer = Color(0xFFE7EEEC),
    surfaceContainerHigh = Color(0xFFE1E9E6), surfaceContainerHighest = Color(0xFFDBE3E1),
)
private val Dark = darkColorScheme(
    primary = Color(0xFF7FD6C6), onPrimary = Color(0xFF00382F),
    primaryContainer = Color(0xFF00504A), onPrimaryContainer = Color(0xFFB7F0E4),
    secondaryContainer = Color(0xFF334B46), onSecondaryContainer = Color(0xFFCCE8E2),
    tertiary = Color(0xFFB2CAE6), tertiaryContainer = Color(0xFF334A63), onTertiaryContainer = Color(0xFFD3E4F8),
    surface = Color(0xFF0E1513), background = Color(0xFF0E1513),
    surfaceContainerLowest = Color(0xFF090F0E), surfaceContainerLow = Color(0xFF151D1B), surfaceContainer = Color(0xFF1A2220),
    surfaceContainerHigh = Color(0xFF242C2A), surfaceContainerHighest = Color(0xFF2F3735),
)

@Composable
fun MydroidTheme(dark: Boolean = isSystemInDarkTheme(), dynamic: Boolean = false, content: @Composable () -> Unit) {
    val ctx = LocalContext.current
    val scheme = when {
        dynamic && Build.VERSION.SDK_INT >= 31 -> if (dark) dynamicDarkColorScheme(ctx) else dynamicLightColorScheme(ctx)
        dark -> Dark
        else -> Light
    }
    MaterialTheme(colorScheme = scheme, content = content)
}

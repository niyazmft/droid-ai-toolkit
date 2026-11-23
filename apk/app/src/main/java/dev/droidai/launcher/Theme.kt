package dev.droidai.launcher

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/**
 * Colour tokens taken from the design mock-up (Material 3 roles, not raw hex sprinkled
 * through the UI). `success` and `warning` are not Material roles, so they are exposed
 * here as plain colours and used only by the status chips.
 */
object Tokens {
    val Success = Color(0xFF146C2E)
    val SuccessContainer = Color(0xFFC4EED0)
    val OnSuccessContainer = Color(0xFF072711)
    val Warning = Color(0xFFB45309)
    val WarningContainer = Color(0xFFFEF3C7)
    val OnWarningContainer = Color(0xFF78350F)
}

private val Light =
    lightColorScheme(
        primary = Color(0xFF0B57D0),
        onPrimary = Color.White,
        primaryContainer = Color(0xFFD3E3FD),
        onPrimaryContainer = Color(0xFF041E49),
        secondary = Color(0xFF4B5D8C),
        onSecondary = Color.White,
        secondaryContainer = Color(0xFFD3E3FD),
        onSecondaryContainer = Color(0xFF041E49),
        error = Color(0xFFB3261E),
        onError = Color.White,
        errorContainer = Color(0xFFF9DEDC),
        onErrorContainer = Color(0xFF410E0B),
        background = Color(0xFFF3F4F8),
        onBackground = Color(0xFF1F1F1F),
        surface = Color(0xFFF3F4F8),
        onSurface = Color(0xFF1F1F1F),
        surfaceVariant = Color(0xFFD8DEE8),
        onSurfaceVariant = Color(0xFF44474E),
        outline = Color(0xFF74777F),
    )

private val Dark =
    darkColorScheme(
        primary = Color(0xFFA8C7FA),
        onPrimary = Color(0xFF00204A),
        primaryContainer = Color(0xFF07326B),
        onPrimaryContainer = Color(0xFFD3E3FD),
        secondary = Color(0xFFB9C6EA),
        onSecondary = Color(0xFF233355),
        secondaryContainer = Color(0xFF3A4A6B),
        onSecondaryContainer = Color(0xFFD9E2FF),
        error = Color(0xFFF2B8B5),
        onError = Color(0xFF601410),
        errorContainer = Color(0xFF601410),
        onErrorContainer = Color(0xFFF9DEDC),
        background = Color(0xFF11131A),
        onBackground = Color(0xFFE3E3E8),
        surface = Color(0xFF11131A),
        onSurface = Color(0xFFE3E3E8),
        surfaceVariant = Color(0xFF2A2E37),
        onSurfaceVariant = Color(0xFFC4C6CF),
        outline = Color(0xFF8E9099),
    )

@Composable
fun DroidTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = if (isSystemInDarkTheme()) Dark else Light,
        content = content,
    )
}

package dev.droidai.launcher

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Identity: soft and quiet, the way a modern chat app looks — Gemini's surfaces and
 * radii, ChatGPT's discipline about colour.
 *
 * Four rules keep it from becoming decoration:
 *
 *   1. Surfaces are neutral and tinted, never branded: a cool page grey, white (or
 *      graphite) cards, one whisper-thin border. No shadows, no gradients.
 *   2. Colour is rationed. A solid black pill in light, a solid white pill in dark, for
 *      the one action on a row. Blue appears only as the selected tab's pill and the
 *      focus ring. Red appears only as a dot marking something that needs you.
 *   3. Radius carries the softness: 16 dp cards, full pills for anything you tap.
 *   4. Inter for everything a person reads. Monospace only where the content *is*
 *      machine output — the raw log and the diagnostic panels — and there it gets a
 *      code-block surface so it reads as deliberate.
 */

/** Roles Material 3 does not model: dividers, tints, the accent, code blocks. */
data class SkinPalette(
    val divider: Color,
    val pressed: Color,
    val accent: Color,
    val accentSoft: Color,
    val codeSurface: Color,
    val ok: Color,
    val warn: Color,
    val danger: Color,
    val neutralDot: Color,
)

private val SkinLight =
    SkinPalette(
        divider = Color(0xFFEDF0F4),
        pressed = Color(0xFFF4F6F9),
        accent = Color(0xFF1A73E8),
        accentSoft = Color(0xFFD3E3FD),
        codeSurface = Color(0xFFF1F3F6),
        ok = Color(0xFF1E8E3E),
        warn = Color(0xFFB06000),
        danger = Color(0xFFD93025),
        neutralDot = Color(0xFFBDC1C6),
    )

private val SkinDark =
    SkinPalette(
        divider = Color(0xFF2A2C2F),
        pressed = Color(0xFF26282B),
        accent = Color(0xFF8AB4F8),
        accentSoft = Color(0xFF20344D),
        codeSurface = Color(0xFF141517),
        ok = Color(0xFF81C995),
        warn = Color(0xFFFDD663),
        danger = Color(0xFFF28B82),
        neutralDot = Color(0xFF6E7378),
    )

private val LocalSkin = staticCompositionLocalOf { SkinLight }

/** `Skin.palette.accent` — the roles Material 3 does not model. */
object Skin {
    val palette: SkinPalette
        @Composable get() = LocalSkin.current
}

/** Inter, bundled and Latin-subset (three weights, ~180 KB total). */
val Inter =
    FontFamily(
        Font(R.font.inter_regular, FontWeight.Normal),
        Font(R.font.inter_medium, FontWeight.Medium),
        Font(R.font.inter_semibold, FontWeight.SemiBold),
    )

/**
 * The few styles the identity needs beyond the Material roles.
 *
 * Tabular figures are deliberate: versions, counts and sizes sit in columns, and Inter
 * aligns them at a fixed width when asked, which is what monospace used to be doing.
 */
object UiType {
    /** Under a tool name: "Installed · v2026.9.8". */
    val meta =
        TextStyle(
            fontFamily = Inter,
            fontWeight = FontWeight.Normal,
            fontSize = 12.sp,
            lineHeight = 16.sp,
            fontFeatureSettings = "tnum",
        )

    /** Group labels above a card, and the header's device line. */
    val subtle =
        TextStyle(
            fontFamily = Inter,
            fontWeight = FontWeight.Medium,
            fontSize = 13.sp,
            lineHeight = 18.sp,
            fontFeatureSettings = "tnum",
        )

    /** Pill button labels. */
    val pill =
        TextStyle(
            fontFamily = Inter,
            fontWeight = FontWeight.Medium,
            fontSize = 13.5.sp,
            lineHeight = 18.sp,
        )

    /** Bottom-bar labels. */
    val tab =
        TextStyle(
            fontFamily = Inter,
            fontWeight = FontWeight.Medium,
            fontSize = 11.sp,
            lineHeight = 14.sp,
        )

    /** Machine output: logs and diagnostics. */
    val code =
        TextStyle(
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.Normal,
            fontSize = 11.5.sp,
            lineHeight = 17.sp,
        )
}

private val Light =
    lightColorScheme(
        primary = Color(0xFF1B1C1D),
        onPrimary = Color(0xFFFFFFFF),
        primaryContainer = Color(0xFFE8F0FE),
        onPrimaryContainer = Color(0xFF174EA6),
        secondary = Color(0xFF5F6368),
        onSecondary = Color(0xFFFFFFFF),
        secondaryContainer = Color(0xFFE8EAED),
        onSecondaryContainer = Color(0xFF202124),
        error = Color(0xFFD93025),
        onError = Color(0xFFFFFFFF),
        errorContainer = Color(0xFFFCE8E6),
        onErrorContainer = Color(0xFF8C1D18),
        background = Color(0xFFF0F4F9),
        onBackground = Color(0xFF1B1C1D),
        surface = Color(0xFFFFFFFF),
        onSurface = Color(0xFF1B1C1D),
        surfaceVariant = Color(0xFFF1F3F6),
        onSurfaceVariant = Color(0xFF5F6368),
        outline = Color(0xFFDDE3EA),
        outlineVariant = Color(0xFFEDF0F4),
    )

private val Dark =
    darkColorScheme(
        primary = Color(0xFFFFFFFF),
        onPrimary = Color(0xFF1B1C1D),
        primaryContainer = Color(0xFF22303F),
        onPrimaryContainer = Color(0xFFD3E3FD),
        secondary = Color(0xFF9AA0A6),
        onSecondary = Color(0xFF1B1C1D),
        secondaryContainer = Color(0xFF2A2C2F),
        onSecondaryContainer = Color(0xFFE8EAED),
        error = Color(0xFFF28B82),
        onError = Color(0xFF3B1D1B),
        errorContainer = Color(0xFF3B1D1B),
        onErrorContainer = Color(0xFFFFDAD6),
        background = Color(0xFF161719),
        onBackground = Color(0xFFE8EAED),
        surface = Color(0xFF1F2123),
        onSurface = Color(0xFFE8EAED),
        surfaceVariant = Color(0xFF2A2C2F),
        onSurfaceVariant = Color(0xFF9AA0A6),
        outline = Color(0xFF303336),
        outlineVariant = Color(0xFF2A2C2F),
    )

private val Type =
    Typography(
        headlineMedium =
            TextStyle(
                fontFamily = Inter,
                fontWeight = FontWeight.SemiBold,
                fontSize = 24.sp,
                lineHeight = 30.sp,
                letterSpacing = (-0.3).sp,
            ),
        headlineSmall =
            TextStyle(
                fontFamily = Inter,
                fontWeight = FontWeight.SemiBold,
                fontSize = 20.sp,
                lineHeight = 26.sp,
                letterSpacing = (-0.2).sp,
            ),
        titleLarge =
            TextStyle(fontFamily = Inter, fontWeight = FontWeight.Medium, fontSize = 18.sp, lineHeight = 24.sp),
        titleMedium =
            TextStyle(fontFamily = Inter, fontWeight = FontWeight.Medium, fontSize = 16.sp, lineHeight = 22.sp),
        titleSmall =
            TextStyle(fontFamily = Inter, fontWeight = FontWeight.Medium, fontSize = 14.sp, lineHeight = 20.sp),
        bodyLarge = TextStyle(fontFamily = Inter, fontSize = 15.sp, lineHeight = 22.sp),
        bodyMedium = TextStyle(fontFamily = Inter, fontSize = 14.sp, lineHeight = 21.sp),
        bodySmall = TextStyle(fontFamily = Inter, fontSize = 13.sp, lineHeight = 19.sp),
        labelLarge = TextStyle(fontFamily = Inter, fontWeight = FontWeight.Medium, fontSize = 13.sp, lineHeight = 18.sp),
        labelMedium = TextStyle(fontFamily = Inter, fontWeight = FontWeight.Medium, fontSize = 12.sp, lineHeight = 16.sp),
        labelSmall = TextStyle(fontFamily = Inter, fontSize = 12.sp, lineHeight = 16.sp),
    )

/** 16 dp cards, full pills. Nothing here is a square corner. */
private val Shapes =
    Shapes(
        extraSmall = androidx.compose.foundation.shape.RoundedCornerShape(8.dp),
        small = androidx.compose.foundation.shape.RoundedCornerShape(12.dp),
        medium = androidx.compose.foundation.shape.RoundedCornerShape(16.dp),
        large = androidx.compose.foundation.shape.RoundedCornerShape(20.dp),
        extraLarge = androidx.compose.foundation.shape.RoundedCornerShape(28.dp),
    )

@Composable
fun DroidTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    CompositionLocalProvider(LocalSkin provides if (darkTheme) SkinDark else SkinLight) {
        MaterialTheme(
            colorScheme = if (darkTheme) Dark else Light,
            typography = Type,
            shapes = Shapes,
            content = content,
        )
    }
}

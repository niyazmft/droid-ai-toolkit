package dev.droidai.launcher

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathBuilder
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.unit.dp

/**
 * Two icons that material-icons-core does not ship, drawn as vectors instead of pulling
 * in material-icons-extended (~2-4 MB of unused icons). Everything else uses the core
 * set, which R8 shrinks to the handful actually referenced.
 */
private fun icon(
    name: String,
    block: PathBuilder.() -> Unit,
): ImageVector =
    ImageVector
        .Builder(
            name = name,
            defaultWidth = 24.dp,
            defaultHeight = 24.dp,
            viewportWidth = 24f,
            viewportHeight = 24f,
        ).apply {
            path(fill = SolidColor(Color.White), pathBuilder = block)
        }.build()

/** A prompt: chevron inside a rounded rectangle. */
val TerminalIcon: ImageVector by lazy {
    icon("Terminal") {
        moveTo(4f, 5f)
        lineTo(20f, 5f)
        lineTo(20f, 19f)
        lineTo(4f, 19f)
        close()
        // inner cut-out is drawn as the background colour by the caller; keep it solid
        // and rely on the tint, so a simple filled glyph is enough here.
        moveTo(8f, 9f)
        lineTo(11f, 12f)
        lineTo(8f, 15f)
        lineTo(9.4f, 16.4f)
        lineTo(13.8f, 12f)
        lineTo(9.4f, 7.6f)
        close()
    }
}

/** Three bars of increasing height: the metrics tab. */
val MetricsIcon: ImageVector by lazy {
    icon("Metrics") {
        moveTo(5f, 13f)
        lineTo(8f, 13f)
        lineTo(8f, 19f)
        lineTo(5f, 19f)
        close()
        moveTo(10.5f, 9f)
        lineTo(13.5f, 9f)
        lineTo(13.5f, 19f)
        lineTo(10.5f, 19f)
        close()
        moveTo(16f, 5f)
        lineTo(19f, 5f)
        lineTo(19f, 19f)
        lineTo(16f, 19f)
        close()
    }
}

package dev.droidai.launcher

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

/**
 * The primitives the soft identity is built from.
 *
 * Everything is a tinted surface with a whisper border and a generous radius; nothing is
 * elevated, and the only saturated colour in the whole vocabulary is a state dot.
 *
 * A group of rows is white (or graphite) on the tinted page: 16 dp radius, 1 dp hairline.
 */
@Composable
fun UiCard(
    modifier: Modifier = Modifier,
    contentPadding: PaddingValues = PaddingValues(16.dp),
    spacing: androidx.compose.ui.unit.Dp = 10.dp,
    content: @Composable ColumnScope.() -> Unit,
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        color = MaterialTheme.colorScheme.surface,
        shape = MaterialTheme.shapes.medium,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
    ) {
        Column(
            Modifier.padding(contentPadding),
            verticalArrangement = Arrangement.spacedBy(spacing),
            content = content,
        )
    }
}

/** A hairline *inside* a card, between two rows. */
@Composable
fun UiDivider(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().height(1.dp).background(Skin.palette.divider))
}

enum class StateTone { PLAIN, OK, ATTENTION }

/**
 * A state line: a dot and a word, no background.
 *
 * This replaced the tinted chip. A chip competes with the row's own text for attention,
 * and in a list where most rows are "Installed" that is the wrong thing to emphasise. A
 * dot carries the colour, the word carries the meaning, and neither shouts.
 */
@Composable
fun UiState(
    text: String,
    tone: StateTone = StateTone.PLAIN,
    modifier: Modifier = Modifier,
) {
    val p = Skin.palette
    val dot =
        when (tone) {
            StateTone.PLAIN -> p.neutralDot
            StateTone.OK -> p.ok
            StateTone.ATTENTION -> p.danger
        }
    Row(
        modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(Modifier.size(6.dp).background(dot, CircleShape))
        Text(
            text,
            style = UiType.meta,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/**
 * The one action on a row.
 *
 * `primary` is a solid pill in the ink colour — black on paper, white on graphite — which
 * is how ChatGPT draws its only button. No blue: blue is reserved for "where am I" and
 * "what has focus".
 *
 * `ghost` used to be *bare grey text*, and that was a usability bug reported from the phone:
 * "Open Advanced", "Test now", "Re-check status" and "Check again" all looked like disabled
 * labels, so nobody knew they were tappable. A quiet action is now a hairline **outlined**
 * pill in the ink colour: unmistakably a button, still obviously secondary to the solid one
 * next to it. Only the *disabled* state is grey-on-no-border, which is what makes the
 * difference between "quiet" and "unavailable" readable at all.
 */
@Composable
fun UiPill(
    label: String,
    onClick: () -> Unit,
    enabled: Boolean = true,
    ghost: Boolean = false,
) {
    val bg = MaterialTheme.colorScheme.primary
    val fg = MaterialTheme.colorScheme.onPrimary
    if (ghost) {
        Surface(
            onClick = onClick,
            enabled = enabled,
            shape = CircleShape,
            color = Color.Transparent,
            contentColor = MaterialTheme.colorScheme.onSurface,
            border =
                BorderStroke(
                    1.dp,
                    if (enabled) {
                        MaterialTheme.colorScheme.outline
                    } else {
                        MaterialTheme.colorScheme.outline.copy(alpha = 0.4f)
                    },
                ),
            modifier = Modifier.heightIn(min = 40.dp).semantics { role = Role.Button },
        ) {
            Box(Modifier.padding(horizontal = 16.dp, vertical = 9.dp), contentAlignment = Alignment.Center) {
                Text(
                    label,
                    style = UiType.pill,
                    color =
                        if (enabled) {
                            MaterialTheme.colorScheme.onSurface
                        } else {
                            MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f)
                        },
                )
            }
        }
        return
    }
    Surface(
        onClick = onClick,
        enabled = enabled,
        shape = CircleShape,
        color = if (enabled) bg else bg.copy(alpha = 0.3f),
        contentColor = fg,
        modifier = Modifier.heightIn(min = 38.dp),
    ) {
        Box(Modifier.padding(horizontal = 18.dp, vertical = 9.dp), contentAlignment = Alignment.Center) {
            Text(label, style = UiType.pill, color = fg)
        }
    }
}

/**
 * A pill that is either chosen or not: window filters, theme choice.
 *
 * Selected uses the accent tint, which is the same "you are here" signal as the tab bar —
 * so the two controls that carry state read as one idea.
 */
@Composable
fun UiChoice(
    label: String,
    selected: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val p = Skin.palette
    Surface(
        onClick = onClick,
        modifier = modifier.heightIn(min = 36.dp),
        shape = CircleShape,
        color = if (selected) p.accentSoft else MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, if (selected) Color.Transparent else MaterialTheme.colorScheme.outline),
    ) {
        Box(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), contentAlignment = Alignment.Center) {
            Text(
                label,
                style = UiType.pill,
                color = if (selected) p.accent else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/**
 * The top of a sub-screen: a back arrow, the page's name, and an optional action on the right.
 *
 * Settings, the device facts and the raw output each had their own version of this — a text
 * "Back" button at the top of one, at the bottom of another, an arrow on the third, and two
 * different title sizes. The arrow wins because it is the shape Android users already know, and
 * it now sits in the same place, at the same size, on all three.
 */
@Composable
fun SubScreenHeader(
    title: String,
    onBack: () -> Unit,
    action: @Composable () -> Unit = {},
) {
    Row(
        Modifier.fillMaxWidth().padding(start = 4.dp, end = 16.dp, top = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onBack, modifier = Modifier.size(48.dp)) {
            Icon(
                Icons.Filled.ArrowBack,
                contentDescription = "Back",
                modifier = Modifier.size(22.dp),
            )
        }
        Spacer(Modifier.width(4.dp))
        Text(
            title,
            style = MaterialTheme.typography.headlineSmall,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        action()
    }
}

/**
 * Machine output, on its own surface.
 *
 * Mono is only ever used here and in the raw log, and it gets a tinted block with a 12 dp
 * radius so it reads as a code block rather than as a font inconsistency.
 */
@Composable
fun UiCodeBlock(
    text: String,
    modifier: Modifier = Modifier,
    // / Logs keep their line length: wrapping cuts a run id in half ("1795466327-7 / 013")
    // / and makes a stack trace unreadable. Diagnostics wrap, because they are prose.
    scrollHorizontally: Boolean = false,
) {
    val scroll = if (scrollHorizontally) Modifier.horizontalScroll(rememberScrollState()) else Modifier
    Surface(
        modifier = modifier.fillMaxWidth(),
        color = Skin.palette.codeSurface,
        shape = RoundedCornerShape(12.dp),
        // A border as well as a fill: a code block tinted one or two values away from the
        // page is invisible on a phone in daylight.
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
    ) {
        Text(
            text,
            style = UiType.code,
            color = MaterialTheme.colorScheme.onSurface,
            softWrap = !scrollHorizontally,
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp).then(scroll),
        )
    }
}

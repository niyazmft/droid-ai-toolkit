package dev.droidai.launcher

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.dp

/**
 * The last run's stdout, filterable by tool.
 *
 * Filters are substring matches because that is what the stream actually contains: a
 * single NDJSON run whose lines mention the tool they concern (`pm2`, `openclaw`,
 * `hermes`). Pretending to know more structure than that would be a lie the data cannot
 * support yet.
 */
@Composable
fun RawOutputScreen(
    raw: String,
    retained: Boolean = true,
    onBack: () -> Unit,
) {
    val clipboard = LocalClipboardManager.current
    var filter by remember { mutableStateOf("All") }
    val filters = listOf("All", "pm2", "openclaw", "hermes")

    val lines =
        remember(raw, filter) {
            raw
                .lineSequence()
                .filter { line -> filter == "All" || line.contains(filter, ignoreCase = true) }
                .toList()
        }

    Column(
        Modifier.fillMaxSize().padding(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) {
                Icon(Icons.Filled.ArrowBack, contentDescription = stringResource(R.string.raw_back))
            }
            Text(
                stringResource(R.string.raw_raw_output),
                style = MaterialTheme.typography.titleLarge,
                modifier = Modifier.weight(1f),
            )
            UiPill(
                label = stringResource(R.string.raw_copy),
                ghost = true,
                onClick = { clipboard.setText(AnnotatedString(raw)) },
            )
        }

        Row(
            Modifier.horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            filters.forEach { f ->
                // Disabled-looking, not disabled: tapping the active filter is a no-op,
                // and a chip that cannot be tapped would drop out of TalkBack's ordering.
                UiChoice(label = f, selected = filter == f) {
                    if (filter != f) filter = f
                }
            }
        }

        if (!retained) {
            Text(
                stringResource(R.string.raw_raw_output_retention_is_off_settings),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        } else if (raw.isBlank()) {
            Text(
                stringResource(R.string.raw_nothing_captured_yet_run_an_action),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        } else {
            Text(
                stringResource(R.string.raw_of_line_s, lines.size, raw.lineSequence().count()),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Column(Modifier.verticalScroll(rememberScrollState())) {
                UiCodeBlock(lines.joinToString("\n"), scrollHorizontally = true)
            }
        }
    }
}

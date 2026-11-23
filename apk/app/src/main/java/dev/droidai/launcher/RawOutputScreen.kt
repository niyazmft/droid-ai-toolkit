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
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
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
                Icon(Icons.Filled.ArrowBack, contentDescription = "Back")
            }
            Text("Raw Output", style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
            TextButton(onClick = { clipboard.setText(AnnotatedString(raw)) }) { Text("Copy") }
        }

        Row(
            Modifier.horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            filters.forEach { f ->
                AssistChip(
                    onClick = { filter = f },
                    label = { Text(f) },
                    enabled = filter != f,
                )
            }
        }

        if (raw.isBlank()) {
            Text(
                "Nothing captured yet. Run an action and its output appears here.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        } else {
            Text(
                "${lines.size} of ${raw.lineSequence().count()} line(s)",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Panel {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    Text(
                        lines.joinToString("\n"),
                        fontFamily = FontFamily.Monospace,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
        }
    }
}

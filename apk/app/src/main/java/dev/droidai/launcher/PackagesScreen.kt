package dev.droidai.launcher

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

/**
 * Tools as tools, not as actions.
 *
 * The catalog is flat — `openclaw.install`, `openclaw.uninstall`, `pi.install`, … — which is
 * right for the engine but reads as a wall of verbs in the UI. This screen regroups it by
 * tool, which is the shape the TUI has always had (AGENTS → OpenClaw → Install/Repair/…),
 * and shows the installed version next to each one.
 *
 * Nothing here is new capability: every button is a catalog action. It is the same
 * catalog rendered per tool instead of per category.
 */
private data class ToolRow(
    val key: String,
    val title: String,
    val version: String,
    val actions: List<Protocol.Action>,
)

private fun tools(
    snapshot: Protocol.Snapshot?,
    actions: List<Protocol.Action>,
): List<ToolRow> {
    val known =
        listOf(
            "openclaw" to "OpenClaw",
            "hermes" to "Hermes Agent",
            "n8n" to "n8n",
            "pi" to "Pi coding agent",
            "gemini" to "Gemini CLI",
            "ollama" to "Ollama",
            "paperclip" to "Paperclip",
            "nanobot" to "Nanobot",
        )
    return known
        .map { (key, title) ->
            val version =
                when (key) {
                    "openclaw" -> snapshot?.tools?.openclaw.orEmpty()
                    "hermes" -> snapshot?.tools?.hermes.orEmpty()
                    "n8n" -> snapshot?.tools?.n8n.orEmpty()
                    "ollama" -> snapshot?.tools?.ollama.orEmpty()
                    // Pi and Gemini are not in the status payload: probing them costs seconds
                    // (Gemini's --version took 76 s on 8x), which is not worth slowing every
                    // status refresh for a label.
                    else -> ""
                }
            ToolRow(
                key = key,
                title = title,
                version = version,
                actions = actions.filter { it.id.startsWith("$key.") }.sortedBy { it.id },
            )
        }.filter { it.actions.isNotEmpty() }
}

@Composable
fun PackagesScreen(
    snapshot: Protocol.Snapshot?,
    actions: List<Protocol.Action>,
    running: Boolean,
    onRun: (Protocol.Action) -> Unit,
) {
    val rows = tools(snapshot, actions)

    Column(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text("Packages", style = MaterialTheme.typography.headlineMedium)
        Text(
            "${rows.count { it.version.isNotBlank() }} of ${rows.size} installed",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        rows.forEach { tool ->
            Section(tool.title)
            Panel {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        if (tool.version.isBlank()) "not installed" else tool.version,
                        style = MaterialTheme.typography.bodySmall,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    StatusChip(
                        online = tool.version.isNotBlank(),
                        label = if (tool.version.isNotBlank()) "installed" else "missing",
                    )
                }

                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    tool.actions.forEach { action ->
                        if (action.destructive) {
                            TextButton(onClick = { onRun(action) }, enabled = !running) {
                                Text(
                                    "Remove…",
                                    style = MaterialTheme.typography.labelLarge,
                                    color = MaterialTheme.colorScheme.error,
                                )
                            }
                        } else {
                            Button(onClick = { onRun(action) }, enabled = !running) {
                                // `hermes.install` is the repair path; naming it "Repair"
                                // matches what it does and what the TUI calls it.
                                Text(
                                    when {
                                        // hermes.install is the repair path, whatever the
                                        // version string says.
                                        action.id == "hermes.install" -> "Repair"
                                        // An installed tool's install action is an upgrade.
                                        tool.version.isNotBlank() -> "Update"
                                        else -> "Install"
                                    },
                                    style = MaterialTheme.typography.labelLarge,
                                )
                            }
                        }
                    }
                }

                Text(
                    tool.actions.joinToString(" · ") { it.summary },
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

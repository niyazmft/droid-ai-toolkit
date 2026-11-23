package dev.droidai.launcher

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

/**
 * Tools as tools, not as actions — the shape the TUI has always had, and the shape the
 * packages mock-up asks for: search, category filter, one card per tool with its version,
 * install state and its own verbs.
 *
 * Every button is still a catalog action; this is a rendering, not new capability.
 */
private data class PackageRow(
    val key: String,
    val title: String,
    val meta: String,
    val installed: Boolean,
    val category: String,
    val description: String,
    val actions: List<Protocol.Action>,
)

private val KNOWN_TOOLS =
    listOf(
        Triple("openclaw", "OpenClaw gateway", "agents"),
        Triple("hermes", "Hermes Agent", "agents"),
        Triple("pi", "Pi coding agent", "agents"),
        Triple("nanobot", "Nanobot", "agents"),
        Triple("ollama", "Ollama", "utilities"),
        Triple("gemini", "Gemini CLI", "utilities"),
        Triple("n8n", "n8n", "workflows"),
        Triple("paperclip", "Paperclip", "workflows"),
    )

/** What each tool is for, in the words of someone who has not used it before. */
private val TOOL_BLURB =
    mapOf(
        "openclaw" to "A personal agent gateway — connects your agents to chat apps.",
        "hermes" to "Nous Research's agent, with tools and memory.",
        "pi" to "A lightweight coding agent you can run from the terminal.",
        "nanobot" to "A small agent runtime for scripts and tasks.",
        "ollama" to "Runs AI models locally on this device.",
        "gemini" to "Google's Gemini command-line assistant.",
        "n8n" to "Automate things with workflows, like a self-hosted Zapier.",
        "paperclip" to "A workflow canvas with a web interface.",
    )

private fun versionOf(
    snapshot: Protocol.Snapshot?,
    key: String,
): String =
    when (key) {
        "openclaw" -> snapshot?.tools?.openclaw.orEmpty()
        "hermes" -> snapshot?.tools?.hermes.orEmpty()
        "n8n" -> snapshot?.tools?.n8n.orEmpty()
        "ollama" -> snapshot?.tools?.ollama.orEmpty()
        // Pi, Gemini, Paperclip and Nanobot are not in the status payload: probing them costs
        // seconds per refresh (Gemini's --version took 76 s on 8x).
        else -> ""
    }

/**
 * The verb on the button.
 *
 * It used to be `action.id == "hermes.install" -> "Repair"` unconditionally, so a device
 * that had never installed Hermes was offered "Repair" — a word that means "something is
 * broken" to someone who is not looking at a repository. Also: every action used to be
 * labelled the same way, so two buttons reading "Update" were indistinguishable by
 * sight and to TalkBack.
 */
private fun actionLabel(
    action: Protocol.Action,
    installed: Boolean,
): String =
    when {
        action.destructive -> "Remove…"
        action.id.startsWith("hermes.") && installed -> "Repair"
        installed -> "Update"
        else -> "Install"
    }

private fun rows(
    snapshot: Protocol.Snapshot?,
    actions: List<Protocol.Action>,
): List<PackageRow> =
    KNOWN_TOOLS.mapNotNull { (key, title, category) ->
        val mine = actions.filter { it.id.startsWith("$key.") }.sortedBy { it.id }
        if (mine.isEmpty()) return@mapNotNull null
        val version = versionOf(snapshot, key)
        PackageRow(
            key = key,
            title = title,
            // The mock shows a version plus a runtime hint; when no version is available,
            // name where it lives rather than invent one.
            meta = version.ifBlank { "tools/$key" },
            installed = version.isNotBlank(),
            category = category,
            description = TOOL_BLURB[key] ?: mine.joinToString(" ") { it.summary },
            actions = mine,
        )
    }

@Composable
fun PackagesScreen(
    snapshot: Protocol.Snapshot?,
    actions: List<Protocol.Action>,
    running: Boolean,
    onRun: (Protocol.Action) -> Unit,
) {
    var query by rememberSaveable { mutableStateOf("") }
    var category by rememberSaveable { mutableStateOf("All") }

    val all = remember(snapshot, actions) { rows(snapshot, actions) }
    val visible =
        all.filter { row ->
            (category == "All" || row.category == category.lowercase()) &&
                (query.isBlank() || row.title.contains(query, ignoreCase = true))
        }

    Column(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text("Packages", style = MaterialTheme.typography.headlineMedium)
        Text(
            "${all.count { it.installed }} of ${all.size} installed · ${snapshot?.device?.arch ?: "—"}",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        OutlinedTextField(
            value = query,
            onValueChange = { query = it },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            shape = RoundedCornerShape(50),
            placeholder = { Text("Search OpenClaw, Hermes, Ollama…") },
            leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
            trailingIcon = {
                if (query.isNotEmpty()) {
                    IconButton(onClick = { query = "" }) {
                        Icon(Icons.Filled.Clear, contentDescription = "Clear search")
                    }
                }
            },
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        )

        // Was a plain Row: "Workflows" wrapped onto two lines and made the chip row
        // uneven. Scrolling horizontally keeps one line at any font scale.
        Row(
            Modifier.horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            listOf("All", "Agents", "Utilities", "Workflows").forEach { c ->
                // FilterChip, not a disabled AssistChip: the old code greyed the selected
                // chip out, so the chosen filter looked switched off and dropped out of
                // the TalkBack focus order.
                FilterChip(
                    selected = category == c,
                    onClick = { category = c },
                    label = { Text(c) },
                    modifier = Modifier.heightIn(min = 40.dp),
                )
            }
        }

        if (visible.isEmpty()) {
            Text(
                if (query.isNotBlank()) {
                    "No tool matches \"$query\"."
                } else {
                    "Nothing in this category."
                },
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        visible.forEach { row ->
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors =
                    CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f),
                    ),
            ) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(row.title, style = MaterialTheme.typography.titleSmall)
                            Text(
                                row.meta,
                                style = MaterialTheme.typography.labelSmall,
                                fontFamily = FontFamily.Monospace,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        StatusChip(
                            online = row.installed,
                            label = if (row.installed) "Installed" else "Not installed",
                            // "Not installed" is a state, not a fault: the error colour
                            // made every uninstalled tool look broken.
                            neutral = !row.installed,
                        )
                    }

                    Text(
                        row.description,
                        style = MaterialTheme.typography.bodySmall,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                    )

                    Row(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.End,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        row.actions.forEach { action ->
                            if (action.destructive) {
                                TextButton(
                                    onClick = { onRun(action) },
                                    enabled = !running,
                                    modifier = Modifier.heightIn(min = 48.dp),
                                ) {
                                    Text(
                                        actionLabel(action, row.installed),
                                        style = MaterialTheme.typography.labelLarge,
                                        color = MaterialTheme.colorScheme.error,
                                    )
                                }
                            } else {
                                Button(
                                    onClick = { onRun(action) },
                                    enabled = !running,
                                    modifier = Modifier.heightIn(min = 48.dp),
                                ) {
                                    Text(
                                        actionLabel(action, row.installed),
                                        style = MaterialTheme.typography.labelLarge,
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

package dev.droidai.launcher

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
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
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

/**
 * Tools as tools, grouped by what the user can act on, not by our taxonomy.
 *
 * The category chips (All / Agents / Utilities / Workflows) were the wrong axis: they
 * described how the catalog is filed internally rather than answering "what do I have, and
 * what is broken". A phone screen has room for the answer, not for the filing cabinet.
 *
 * Three groups, in the order a person actually needs them:
 *
 *   Needs attention — installed but something is wrong, with the reason on the card
 *   Installed       — present and quiet
 *   Not installed   — the catalog
 *
 * A tool appears in exactly one of them. Sections collapse, and the one the user is most
 * likely to want (Installed) is open first; Not installed opens by itself on a device that
 * has nothing yet, because then the catalog *is* the screen.
 */
private enum class Group {
    ATTENTION,
    INSTALLED,
    AVAILABLE,
}

private data class ToolRow(
    val key: String,
    val title: String,
    val blurb: String,
    val version: String,
    val installed: Boolean,
    val issue: String?,
    val actions: List<Protocol.Action>,
) {
    val group: Group
        get() =
            when {
                issue != null -> Group.ATTENTION
                installed -> Group.INSTALLED
                else -> Group.AVAILABLE
            }
}

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
        "openclaw" to "A personal agent gateway that connects your agents to chat apps.",
        "hermes" to "Nous Research's agent, with tools and memory.",
        "pi" to "A lightweight coding agent you can run from the terminal.",
        "nanobot" to "A small agent runtime for scripts and tasks.",
        "ollama" to "Runs AI models locally on this device.",
        "gemini" to "Google's Gemini command-line assistant.",
        "n8n" to "Automate things with workflows, like a self-hosted Zapier.",
        "paperclip" to "A workflow canvas with a web interface.",
    )

/**
 * Where the engine says a tool lives.
 *
 * `tools.installed` is authoritative: the engine stats the per-tool directory, so it costs
 * nothing and cannot be confused by a blank version string. The version fallback exists
 * only for an engine older than that field.
 */
private fun isInstalled(
    snapshot: Protocol.Snapshot?,
    key: String,
): Boolean {
    snapshot
        ?.tools
        ?.installed
        ?.get(key)
        ?.let { return it }
    val v = versionOf(snapshot, key)
    return v.isNotBlank()
}

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
 * Why this tool needs attention, or null.
 *
 * Three signals, each stated on the card so the group is never a mystery:
 *
 *   Disappeared      — we recorded it installed and the files are gone
 *   Service stopped  — it has a PM2 process that is not online (the "my bot went quiet" case)
 *   Last attempt failed — an install/repair run here ended non-zero
 */
private fun issueFor(
    key: String,
    installed: Boolean,
    snapshot: Protocol.Snapshot?,
    knownInstalled: Set<String>,
    failedTools: Set<String>,
): String? {
    if (!installed && key in knownInstalled) return "Disappeared — its files are gone"
    if (installed) {
        val svc = snapshot?.services?.firstOrNull { it.name.equals(key, ignoreCase = true) }
        if (svc != null && svc.status != "online") return "Service stopped"
    }
    if (key in failedTools) return "Last attempt failed"
    return null
}

private fun rows(
    snapshot: Protocol.Snapshot?,
    actions: List<Protocol.Action>,
    knownInstalled: Set<String>,
    failedTools: Set<String>,
): List<ToolRow> =
    KNOWN_TOOLS.mapNotNull { (key, title, _) ->
        val mine = actions.filter { it.id.startsWith("$key.") }.sortedBy { it.id }
        if (mine.isEmpty()) return@mapNotNull null
        val installed = isInstalled(snapshot, key)
        ToolRow(
            key = key,
            title = title,
            blurb = TOOL_BLURB[key] ?: mine.joinToString(" ") { it.summary },
            version = Format.toolVersion(versionOf(snapshot, key)),
            installed = installed,
            issue = issueFor(key, installed, snapshot, knownInstalled, failedTools),
            actions = mine,
        )
    }

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

@Composable
fun PackagesScreen(
    snapshot: Protocol.Snapshot?,
    actions: List<Protocol.Action>,
    running: Boolean,
    knownInstalled: Set<String> = emptySet(),
    failedTools: Set<String> = emptySet(),
    onRun: (Protocol.Action) -> Unit,
) {
    var query by rememberSaveable { mutableStateOf("") }

    val all =
        remember(snapshot, actions, knownInstalled, failedTools) {
            rows(snapshot, actions, knownInstalled, failedTools)
        }

    val matching =
        all.filter { row ->
            query.isBlank() ||
                row.title.contains(query, ignoreCase = true) ||
                row.blurb.contains(query, ignoreCase = true)
        }

    val attention = matching.filter { it.group == Group.ATTENTION }
    val installed = matching.filter { it.group == Group.INSTALLED }
    val available = matching.filter { it.group == Group.AVAILABLE }

    // Open the useful ones; open the catalog only when the device has nothing yet, because
    // a fresh install must not present three collapsed headers and no way forward.
    var attentionOpen by rememberSaveable { mutableStateOf<Boolean?>(null) }
    var installedOpen by rememberSaveable { mutableStateOf<Boolean?>(null) }
    var availableOpen by rememberSaveable { mutableStateOf<Boolean?>(null) }

    val attentionExpanded = attentionOpen ?: true
    val installedExpanded = installedOpen ?: true
    val availableExpanded = availableOpen ?: (installed.isEmpty() && attention.isEmpty())

    Column(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text("Packages", style = MaterialTheme.typography.headlineMedium)
        Text(
            "${all.count { it.installed }} of ${all.size} installed",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        // 40 dp, not 56: the old field was a Material text field whose placeholder wrapped
        // onto a second line, so a single-purpose search box occupied as much room as a
        // tool card. BasicTextField inside a pill keeps it to one line of chrome.
        SearchField(query) { query = it }

        if (matching.isEmpty()) {
            Text(
                "No tool matches \"$query\".",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        if (attention.isNotEmpty()) {
            SectionHeader("Needs attention", attention.size, attentionExpanded) {
                attentionOpen = !attentionExpanded
            }
            if (attentionExpanded) {
                attention.forEach { ToolCard(it, running, onRun) }
            }
        }

        if (installed.isNotEmpty()) {
            SectionHeader("Installed", installed.size, installedExpanded) {
                installedOpen = !installedExpanded
            }
            if (installedExpanded) {
                installed.forEach { ToolCard(it, running, onRun) }
            }
        }

        if (available.isNotEmpty()) {
            SectionHeader("Not installed", available.size, availableExpanded) {
                availableOpen = !availableExpanded
            }
            if (availableExpanded) {
                available.forEach { ToolCard(it, running, onRun) }
            }
        }
    }
}

@Composable
private fun SearchField(
    query: String,
    onChange: (String) -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(50),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
        modifier = Modifier.fillMaxWidth().heightIn(min = 40.dp),
    ) {
        Row(
            Modifier.padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.Filled.Search,
                contentDescription = null,
                modifier = Modifier.size(18.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Box(Modifier.weight(1f).padding(horizontal = 8.dp)) {
                if (query.isEmpty()) {
                    Text(
                        "Search tools",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                BasicTextField(
                    value = query,
                    onValueChange = onChange,
                    singleLine = true,
                    textStyle =
                        MaterialTheme.typography.bodyMedium.copy(
                            color = MaterialTheme.colorScheme.onSurface,
                        ),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    modifier =
                        Modifier
                            .fillMaxWidth()
                            .padding(vertical = 10.dp)
                            .semantics { stateDescription = "Search tools" },
                )
            }
            if (query.isNotEmpty()) {
                IconButton(onClick = { onChange("") }, modifier = Modifier.size(32.dp)) {
                    Icon(
                        Icons.Filled.Clear,
                        contentDescription = "Clear search",
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
        }
    }
}

/**
 * A collapsible group header.
 *
 * `stateDescription` is what makes this usable without sight: a screen reader announces
 * "Installed, 4 tools, collapsed, button" instead of four unlabelled words.
 */
@Composable
private fun SectionHeader(
    title: String,
    count: Int,
    expanded: Boolean,
    onToggle: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .clickable(onClickLabel = if (expanded) "Collapse" else "Expand", onClick = onToggle)
            .semantics { stateDescription = if (expanded) "Expanded" else "Collapsed" }
            .padding(top = 12.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            title,
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.weight(1f),
        )
        Text(
            "$count",
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        // Material 3 expand affordance: the standard 24 dp chevron, rotating rather than
        // swapping glyphs. The previous "\u25BE"/"\u25B8" text characters rendered at
        // label size and read as punctuation, not as a control.
        val rotation by animateFloatAsState(if (expanded) 0f else -90f, label = "chevron")
        Icon(
            Icons.Filled.KeyboardArrowDown,
            contentDescription = null,
            modifier = Modifier.padding(start = 4.dp).rotate(rotation),
        )
    }
}

@Composable
private fun ToolCard(
    row: ToolRow,
    running: Boolean,
    onRun: (Protocol.Action) -> Unit,
) {
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
                    // A version when the engine gave us one. Never a made-up path: "tools/pi"
                    // described our directory layout, which the user has no reason to know.
                    if (row.version.isNotBlank()) {
                        Text(
                            row.version,
                            style = MaterialTheme.typography.labelSmall,
                            fontFamily = FontFamily.Monospace,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
                when (row.group) {
                    Group.ATTENTION -> StatusChip(online = false, label = "Needs attention")
                    Group.INSTALLED -> StatusChip(online = true, label = "Installed")
                    Group.AVAILABLE -> StatusChip(online = false, label = "Not installed", neutral = true)
                }
            }

            row.issue?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.error,
                )
            }

            Text(
                row.blurb,
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

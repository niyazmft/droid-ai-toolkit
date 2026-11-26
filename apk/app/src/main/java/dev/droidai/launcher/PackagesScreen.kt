package dev.droidai.launcher

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
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
    /** Device cpu, so an unsupported row can say which cpu it has. */
    val cpu: String = "",
    /**
     * False when the action's own `requires.arch` excludes this device.
     *
     * The engine refuses such a run at preflight with exit 3, so offering the button
     * only produces "Command failed (exit 3)" with no explanation — on y6 that was the
     * whole Hermes/Nanobot/Paperclip experience. The catalog already carries the list;
     * the app just has to read it.
     */
    val supported: Boolean = true,
    /**
     * A precondition the engine reports as unmet (PostgreSQL down, no matching wheel).
     *
     * Unlike memory, these are not advisory: the engine refuses, and `--force` does not
     * override them. Naming it on the card replaces a bare exit 3 with a reason.
     */
    val blocked: String? = null,
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
 * Delegates to [Protocol.Snapshot.isInstalled] so there is one rule for "installed" in the
 * app: this file used to carry its own copy, and the ViewModel carried a third, which is
 * how a `--fast` snapshot could report a tool as gone while it served traffic.
 */
private fun isInstalled(
    snapshot: Protocol.Snapshot?,
    key: String,
): Boolean = snapshot?.isInstalled(key) ?: false

private fun versionOf(
    snapshot: Protocol.Snapshot?,
    key: String,
): String = snapshot?.versionOf(key).orEmpty()

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
        // The install action carries the arch restriction; its uninstall sibling is
        // deliberately unrestricted (removing something must work on any cpu).
        val install = mine.firstOrNull { it.id.endsWith(".install") }
        val archs = install?.arch.orEmpty()
        val cpu = snapshot?.device?.arch.orEmpty()
        val supported = archs.isEmpty() || cpu.isBlank() || archs.any { it.equals(cpu, ignoreCase = true) }
        // Only the engine's negative answers matter; an older engine sends no `checks`
        // at all, and then nothing is claimed about the precondition.
        val unmet =
            install
                ?.predicates
                .orEmpty()
                .filter { snapshot?.checks?.get(it) == false }
        val blocked = unmet.firstOrNull()?.let { Protocol.checkLabel(it) }
        ToolRow(
            key = key,
            title = title,
            blurb = TOOL_BLURB[key] ?: mine.joinToString(" ") { it.summary },
            version = Format.toolVersion(versionOf(snapshot, key)),
            installed = installed,
            issue = issueFor(key, installed, snapshot, knownInstalled, failedTools),
            actions = mine,
            cpu = cpu,
            supported = supported,
            blocked = blocked,
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
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
            Text(stringResource(R.string.tools_tools), style = MaterialTheme.typography.headlineMedium)
            Spacer(Modifier.weight(1f))
            Text(
                stringResource(R.string.tools_of_installed, all.count { it.installed }, all.size),
                style = UiType.meta,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                // Sits on the title's baseline rather than on the row's box.
                modifier = Modifier.padding(bottom = 4.dp),
            )
        }

        SearchField(query) { query = it }

        if (matching.isEmpty()) {
            // Only an actual search says "nothing matches". With no query and no catalog
            // yet, the honest line is that the list is still being read.
            Text(
                if (query.isBlank()) "Reading the tool list…" else "Nothing matches \"$query\"",
                style = UiType.meta,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        if (attention.isNotEmpty()) {
            GroupSection("Needs attention", attention, attentionExpanded, running, onRun) {
                attentionOpen = !attentionExpanded
            }
        }

        if (installed.isNotEmpty()) {
            GroupSection("Installed", installed, installedExpanded, running, onRun) {
                installedOpen = !installedExpanded
            }
        }

        if (available.isNotEmpty()) {
            GroupSection("Not installed", available, availableExpanded, running, onRun) {
                availableOpen = !availableExpanded
            }
        }
    }
}

/**
 * Label, then one card holding every row in the group.
 *
 * The group is the card, not each row: that is what keeps "Installed" and "Not installed"
 * as two objects on the page instead of a flat list, and it is where the 16 dp radius
 * does its work.
 */
@Composable
private fun GroupSection(
    title: String,
    rows: List<ToolRow>,
    expanded: Boolean,
    running: Boolean,
    onRun: (Protocol.Action) -> Unit,
    onToggle: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        GroupHeader(title, rows.size, expanded, onToggle)
        if (expanded) {
            UiCard(contentPadding = PaddingValues(0.dp), spacing = 0.dp) {
                rows.forEachIndexed { index, row ->
                    if (index > 0) {
                        UiDivider(Modifier.padding(horizontal = 16.dp))
                    }
                    ToolRow(row, running, onRun)
                }
            }
        }
    }
}

/**
 * A collapsible group label.
 *
 * `stateDescription` is what makes this usable without sight: a screen reader announces
 * "Installed, 3 tools, collapsed, button" instead of three unlabelled words.
 */
@Composable
private fun GroupHeader(
    title: String,
    count: Int,
    expanded: Boolean,
    onToggle: () -> Unit,
) {
    // Resolved here, not inside the modifiers: `semantics { }` is a receiver lambda, not a
    // composable scope, so stringResource cannot be called from inside it.
    val actionLabel = if (expanded) stringResource(R.string.tools_collapse) else stringResource(R.string.tools_expand)
    val stateText = if (expanded) stringResource(R.string.tools_expanded) else stringResource(R.string.tools_collapsed)

    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 40.dp)
            .clickable(
                onClickLabel = actionLabel,
                role = Role.Button,
                onClick = onToggle,
            ).semantics { stateDescription = stateText },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            title,
            style = UiType.subtle,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.width(8.dp))
        Text(
            stringResource(R.string.tools_text, count),
            style = UiType.meta,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.weight(1f))
        val rotation by animateFloatAsState(if (expanded) 0f else -90f, label = stringResource(R.string.tools_chevron))
        Icon(
            Icons.Filled.KeyboardArrowDown,
            contentDescription = null,
            modifier = Modifier.size(18.dp).rotate(rotation),
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/**
 * Search.
 *
 * A pill, because that is the shape this vocabulary uses for anything you touch. The
 * placeholder and the field share one fixed-height box, so the two lines cannot drift
 * apart — the previous design's prompt sat high because only the field was padded.
 */
@Composable
private fun SearchField(
    query: String,
    onChange: (String) -> Unit,
) {
    Surface(
        modifier = Modifier.fillMaxWidth().height(52.dp),
        color = MaterialTheme.colorScheme.surface,
        shape = CircleShape,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
    ) {
        Row(
            Modifier.fillMaxWidth().height(52.dp).padding(start = 16.dp, end = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.Filled.Search,
                contentDescription = null,
                modifier = Modifier.size(18.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Box(
                Modifier.weight(1f).height(52.dp).padding(start = 10.dp, end = 8.dp),
                contentAlignment = Alignment.CenterStart,
            ) {
                if (query.isEmpty()) {
                    Text(
                        stringResource(R.string.tools_search_tools),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
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
                    // The one place the accent appears in an input: the caret.
                    cursorBrush = SolidColor(Skin.palette.accent),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    modifier =
                        Modifier
                            .fillMaxWidth()
                            .semantics { stateDescription = "Search tools" },
                )
            }
            if (query.isNotEmpty()) {
                Box(
                    Modifier
                        .size(40.dp)
                        .clickable(onClickLabel = stringResource(R.string.tools_clear_search)) { onChange("") }
                        .semantics { role = Role.Button },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.Filled.Clear,
                        contentDescription = stringResource(R.string.tools_clear_search),
                        modifier = Modifier.size(18.dp),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

/**
 * One tool inside the group card.
 *
 * Order is what a person scanning the list needs: name, then state on the line beneath it
 * ("Installed · v2026.9.8", or the reason it needs attention), then what the tool is, then
 * the one action. State is a dot and a word — not a chip — so a list of six installed tools
 * stays quiet and the single broken one is the only red thing on the screen.
 */
@Composable
private fun ToolRow(
    row: ToolRow,
    running: Boolean,
    onRun: (Protocol.Action) -> Unit,
) {
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(row.title, style = MaterialTheme.typography.titleMedium)

        when (row.group) {
            Group.ATTENTION -> UiState(row.issue.orEmpty(), StateTone.ATTENTION)
            Group.INSTALLED ->
                UiState(
                    if (row.version.isNotBlank()) "Installed · v${row.version}" else "Installed",
                    StateTone.OK,
                )
            Group.AVAILABLE ->
                when {
                    !row.supported ->
                        // Said plainly, and before the user taps: this is not a device
                        // fault, the tool has no build for this cpu.
                        UiState(
                            if (row.cpu.isBlank()) "Not available for this device" else "No build for ${row.cpu}",
                            StateTone.PLAIN,
                        )
                    row.blocked != null -> UiState(row.blocked, StateTone.PLAIN)
                    else -> UiState(stringResource(R.string.tools_not_installed), StateTone.PLAIN)
                }
        }

        Text(
            row.blurb,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
        )

        // One button per card, plus a ⋯ for everything else (F3). Two equal-weight pills made
        // every row a decision ("Update or Remove?") when there is one obvious next action;
        // removal lives in the menu, where it is still two taps and still confirmed.
        val runnable = row.supported && row.blocked == null
        val primary = row.actions.firstOrNull { !it.destructive } ?: row.actions.firstOrNull()
        val secondary = row.actions.filter { it !== primary }
        var menuOpen by remember { mutableStateOf(false) }

        Row(
            Modifier.fillMaxWidth().padding(top = 2.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.End),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            primary?.let { action ->
                val usable = runnable || action.destructive
                UiPill(
                    label =
                        when {
                            usable -> actionLabel(action, row.installed)
                            !row.supported -> "Not on this CPU"
                            else -> "Unavailable"
                        },
                    onClick = { onRun(action) },
                    enabled = !running && usable,
                    ghost = action.destructive,
                )
            }
            if (secondary.isNotEmpty()) {
                Box {
                    IconButton(
                        onClick = { menuOpen = true },
                        modifier = Modifier.size(40.dp),
                        enabled = !running,
                    ) {
                        Icon(
                            Icons.Filled.MoreVert,
                            contentDescription = stringResource(R.string.tools_more_actions_for, row.title),
                            modifier = Modifier.size(20.dp),
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        secondary.forEach { action ->
                            val usable = runnable || action.destructive
                            DropdownMenuItem(
                                text = {
                                    Text(
                                        actionLabel(action, row.installed),
                                        color =
                                            if (action.destructive) {
                                                MaterialTheme.colorScheme.error
                                            } else {
                                                MaterialTheme.colorScheme.onSurface
                                            },
                                    )
                                },
                                enabled = usable,
                                onClick = {
                                    menuOpen = false
                                    onRun(action)
                                },
                            )
                        }
                    }
                }
            }
        }
    }
}

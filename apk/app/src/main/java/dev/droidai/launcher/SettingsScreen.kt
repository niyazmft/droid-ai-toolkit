package dev.droidai.launcher

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle

private const val APP_VERSION = "0.1.0"

/**
 * Settings.
 *
 * Split by what actually backs each row: app-local preferences, engine facts read from
 * the status snapshot, and one destructive engine action. A switch that silently did
 * nothing would be worse than no switch.
 */
@Composable
fun SettingsScreen(
    snapshot: Protocol.Snapshot?,
    running: Boolean,
    notificationsGranted: Boolean = true,
    onRefresh: () -> Unit,
    onRecheckPermission: () -> Unit,
    onRequestNotifications: () -> Unit = {},
    onRunAction: (String) -> Unit,
    onOpenAdvanced: () -> Unit = {},
    onBack: () -> Unit = {},
) {
    val context = LocalContext.current
    val autoStart by Prefs.autoStartGateway.collectAsStateWithLifecycle()
    val supervisorOn by Prefs.supervisorEnabled.collectAsStateWithLifecycle()
    val confirmRemove by Prefs.confirmRemove.collectAsStateWithLifecycle()
    val retainRaw by Prefs.retainRaw.collectAsStateWithLifecycle()
    val themeMode by Prefs.themeMode.collectAsStateWithLifecycle()
    // collectAsState, not .value: the row used to keep showing the old answer after
    // "Re-check" succeeded, because reading a StateFlow value is not observable.
    val permission by Gate.permissionGranted.collectAsStateWithLifecycle()
    var confirmCleanup by remember { mutableStateOf(false) }
    // The size is measured by a *full* status read (`du` over a 13 GB tree is skipped under
    // --fast), so the panel asks for one when it needs the number. Once per visit: a fast
    // refresh would answer 0 again and this would loop.
    var sizeAsked by remember { mutableStateOf(false) }

    LaunchedEffect(snapshot?.termux?.legacyGlobalPresent, snapshot?.termux?.legacyGlobalMb) {
        if (snapshot?.termux?.legacyGlobalPresent == true &&
            snapshot.termux.legacyGlobalMb == 0 &&
            !sizeAsked &&
            !running
        ) {
            sizeAsked = true
            onRefresh()
        }
    }

    // No verticalScroll here: this screen is rendered inside the tab content's scroller,
    // and nesting two of them makes Compose measure one with an infinite max height and
    // crash. The parent owns the scrolling.
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text("Settings", style = MaterialTheme.typography.headlineMedium)
        TextButton(onClick = onBack, modifier = Modifier.padding(top = 2.dp)) {
            Text("Back")
        }

        Section("Appearance")
        Panel {
            Text(
                "Both palettes are designed; this only decides which one you look at.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Row(
                Modifier.fillMaxWidth().padding(top = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                ThemeChoice("System", themeMode == Prefs.THEME_SYSTEM, Modifier.weight(1f)) {
                    Prefs.setThemeMode(Prefs.THEME_SYSTEM)
                }
                ThemeChoice("Light", themeMode == Prefs.THEME_LIGHT, Modifier.weight(1f)) {
                    Prefs.setThemeMode(Prefs.THEME_LIGHT)
                }
                ThemeChoice("Dark", themeMode == Prefs.THEME_DARK, Modifier.weight(1f)) {
                    Prefs.setThemeMode(Prefs.THEME_DARK)
                }
            }
        }

        Section("Droid AI")
        Panel {
            Fact("Version", APP_VERSION)
            Fact("Package", context.packageName)
        }

        Section("Startup & Services")
        Panel {
            // Copy per PLAN.md §F3.2: a 230-character subtitle was five lines of prose for a
            // switch. These are ≤ 26 / ≤ 85 chars so each row fits two lines at font scale 1.3.
            SwitchRow(
                title = "Watch in background",
                subtitle = "One notification, checked when you unlock. Off: no warnings, no auto-restart.",
                checked = supervisorOn,
            ) { Prefs.setSupervisorEnabled(it) }
            // The grant is not optional: without it Android hides the notification while the
            // service keeps running, which is the one failure mode with no visible symptom.
            if (supervisorOn && !notificationsGranted) {
                Text(
                    "Notifications are off, so a stopped service goes unnoticed.",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.error,
                )
                UiPill(label = "Turn on notifications", ghost = true, onClick = onRequestNotifications)
            }
            // The old label promised the wrong scope and the wrong condition: the toggle runs
            // `service.resurrect` → `pm2 resurrect`, which restores *every* process in the dump,
            // and it only fires when *nothing* is online (SupervisorPolicy returns HEALTHY as
            // soon as one service is up). One service, not all; stopped, not all-stopped.
            SwitchRow(
                title = "Restart if all stop",
                subtitle = "When every service is offline, try three times, then give up.",
                checked = autoStart,
                // Disabled, not hidden: it can have no effect while nothing is watching, and a
                // tappable switch that does nothing advertises something the app is not doing.
                enabled = supervisorOn,
            ) { Prefs.setAutoStart(it) }
            // Two lines allowed: "Starts after reboot" does not fit the 104 dp label column at
            // font scale 1.3, and F6 turns this row into an action with its own state block.
            FactLong(
                "Starts after reboot",
                when (snapshot?.termux?.bootInstalled) {
                    true -> "set up"
                    false -> "not set up"
                    null -> "unknown"
                },
            )
            Text(
                "Set up in Termux → SERVICES → PM2 → Autostart on Boot.",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            UiPill(label = "Re-read status", enabled = !running, ghost = true, onClick = onRefresh)
        }

        Section("Termux & Safety")
        Panel {
            // Access is a state, not a measurement, so it is a chip — and the two facts below it
            // are one line each at font scale 1.3. They used to wrap into paragraphs because the
            // row split its width by weight; see Fact() for the fixed label column.
            AccessRow(permission)
            val fullVersion = snapshot?.termux?.version.orEmpty()
            // Short form on screen (the pre-release tail is noise here), full string for a
            // screen reader and in Advanced → About. Never ellipsised.
            Fact(
                "Version",
                Format.shortVersion(fullVersion).ifBlank { "—" },
                spoken = fullVersion.ifBlank { "unknown" },
            )
            UiPill(label = "Check again", ghost = true, onClick = onRecheckPermission)
            SwitchRow(
                title = "Ask before removing",
                subtitle = "Confirm before deleting a tool, its files or its shortcuts.",
                checked = confirmRemove,
            ) { Prefs.setConfirmRemove(it) }
            SwitchRow(
                title = "Keep the last command output",
                subtitle = "Useful when asking for help — it is the raw evidence behind a failure.",
                checked = retainRaw,
            ) { Prefs.setRetainRaw(it) }
        }

        Section("Advanced")
        Panel {
            Text(
                "About this phone, background apps, Termux access and the raw output of the last " +
                    "command. All of it optional — nothing here is needed to use a tool.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            UiPill(label = "Open Advanced", ghost = true, onClick = onOpenAdvanced)
        }

        // Hidden entirely when the legacy folder is absent, which is the normal state on a
        // device that has migrated: showing a button that removes nothing and then reports
        // "done" is how 8x claimed a successful cleanup of a folder that was already gone.
        if (snapshot?.termux?.legacyGlobalPresent == true) {
            val migrated = snapshot.checks["tools_migrated"] != false
            val mb = snapshot.termux.legacyGlobalMb
            Section("Cleanup")
            Panel {
                val size =
                    when {
                        mb >= 1024 -> String.format(java.util.Locale.US, "%.1f GB", mb / 1024.0)
                        mb > 0 -> "$mb MB"
                        else -> "size not measured yet"
                    }
                Text(
                    "Legacy package folder · $size",
                    style = MaterialTheme.typography.titleSmall,
                )
                Text(
                    if (migrated) {
                        "Left behind by an earlier version. Nothing uses it now, so it can be removed."
                    } else {
                        // The engine's own refusal, said before the tap. It used to arrive after
                        // it, as "Step failed: Remove legacy project and shims".
                        "Still in use: a tool has not been moved to its own folder yet. " +
                            "Open Tools and update it first."
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                UiPill(
                    label = "Remove it",
                    enabled = !running && migrated,
                    ghost = true,
                    onClick = { confirmCleanup = true },
                )
            }
        }
    }

    if (confirmCleanup) {
        AlertDialog(
            onDismissRequest = { confirmCleanup = false },
            title = { Text("Remove the old package folder?") },
            text = {
                Text(
                    "This deletes the legacy shared pnpm folder and the shortcuts that point " +
                        "at it. Tools already moved to their own folders are unaffected. " +
                        "This cannot be undone.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmCleanup = false
                    onRunAction("service.cleanup-legacy")
                }) { Text("Remove") }
            },
            dismissButton = {
                TextButton(onClick = { confirmCleanup = false }) { Text("Cancel") }
            },
        )
    }
}

/**
 * Can this app run commands in Termux? A state, shown as a chip.
 *
 * It was a Fact row ("Command access · allowed"), which is a sentence-shaped way to say a
 * yes/no thing — and at font scale 1.3 the label wrapped. The chip carries the meaning in its
 * word, so it survives colour blindness and dark mode, and TalkBack reads "Access: Allowed".
 */
@Composable
private fun AccessRow(allowed: Boolean) {
    val value = if (allowed) "Allowed" else "Not allowed"
    Row(
        Modifier
            .fillMaxWidth()
            .semantics(mergeDescendants = true) { contentDescription = "Access: $value" },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            "Access",
            style = MaterialTheme.typography.bodySmall,
            maxLines = 1,
            modifier = Modifier.weight(1f),
        )
        StatusChip(online = allowed, label = value, neutral = !allowed)
    }
}

/**
 * One of three theme choices, as a bordered segment.
 *
 * A segmented row rather than a dropdown: three options fit on one line, and seeing all
 * three next to the current one is the whole point of a theme switch.
 */
@Composable
private fun ThemeChoice(
    label: String,
    selected: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val p = Skin.palette
    Surface(
        onClick = onClick,
        modifier = modifier.heightIn(min = 40.dp),
        shape = CircleShape,
        color = if (selected) p.accentSoft else MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, if (selected) Color.Transparent else MaterialTheme.colorScheme.outline),
    ) {
        Box(Modifier.fillMaxWidth().padding(vertical = 10.dp), contentAlignment = Alignment.Center) {
            Text(
                label,
                style = UiType.pill,
                color = if (selected) p.accent else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/**
 * A labelled switch.
 *
 * `toggleable(role = Role.Switch)` on the whole row makes this one TalkBack stop that
 * announces "Ask before removing, on, switch" and toggles on double-tap. Before this,
 * the title, the subtitle and an unlabelled switch were three separate stops, so a
 * screen-reader user could not tell which setting they were about to change.
 */
@Composable
private fun SwitchRow(
    title: String,
    subtitle: String,
    checked: Boolean,
    enabled: Boolean = true,
    onChange: (Boolean) -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .toggleable(
                value = checked,
                enabled = enabled,
                role = Role.Switch,
                onValueChange = onChange,
            ).padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyMedium)
            Text(
                subtitle,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        // onCheckedChange = null: the row owns the gesture, so the switch cannot be
        // focused twice or toggled twice.
        Switch(checked = checked, onCheckedChange = null, enabled = enabled)
    }
}

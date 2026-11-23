package dev.droidai.launcher

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp

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
    onRefresh: () -> Unit,
    onRecheckPermission: () -> Unit,
    onRunAction: (String) -> Unit,
) {
    val context = LocalContext.current
    val autoStart by Prefs.autoStartGateway.collectAsState()
    val confirmRemove by Prefs.confirmRemove.collectAsState()
    val retainRaw by Prefs.retainRaw.collectAsState()
    // collectAsState, not .value: the row used to keep showing the old answer after
    // "Re-check" succeeded, because reading a StateFlow value is not observable.
    val permission by Gate.permissionGranted.collectAsState()
    var confirmCleanup by remember { mutableStateOf(false) }

    // No verticalScroll here: this screen is rendered inside the tab content's scroller,
    // and nesting two of them makes Compose measure one with an infinite max height and
    // crash. The parent owns the scrolling.
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text("Settings", style = MaterialTheme.typography.headlineMedium)

        Section("Droid AI")
        Panel {
            Fact("Version", APP_VERSION)
            Fact("Package", context.packageName)
            Fact(
                "Device",
                snapshot?.let { "${it.device.model} · Android ${it.device.android} (API ${it.device.api})" } ?: "—",
            )
            Fact("Arch", snapshot?.device?.arch ?: "—")
        }

        Section("Startup & Services")
        Panel {
            SwitchRow(
                title = "Restart the gateway automatically",
                subtitle =
                    "If the OpenClaw gateway stops, try to start it again — up to three " +
                        "times, then stop trying.",
                checked = autoStart,
            ) { Prefs.setAutoStart(it) }
            Fact(
                "Restarts after reboot",
                when (snapshot?.termux?.bootInstalled) {
                    true -> "set up"
                    false -> "not set up"
                    null -> "unknown"
                },
            )
            Text(
                "Reboot support is installed by the toolkit (SERVICES → PM2 → Autostart on Boot).",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            TextButton(
                onClick = onRefresh,
                enabled = !running,
                modifier = Modifier.heightIn(min = 48.dp),
            ) { Text("Re-read status") }
        }

        Section("Termux & Safety")
        Panel {
            Fact("Command access", if (permission) "allowed" else "not allowed")
            Fact("Termux version", snapshot?.termux?.version ?: "—")
            TextButton(
                onClick = onRecheckPermission,
                modifier = Modifier.heightIn(min = 48.dp),
            ) { Text("Check again") }
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

        Section("Cleanup")
        Panel {
            Text(
                "Removes an old shared package folder left behind by earlier versions. " +
                    "Refused while any tool still depends on it.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            TextButton(
                onClick = { confirmCleanup = true },
                enabled = !running,
                modifier = Modifier.heightIn(min = 48.dp),
            ) { Text("Remove the old package folder", color = MaterialTheme.colorScheme.error) }
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

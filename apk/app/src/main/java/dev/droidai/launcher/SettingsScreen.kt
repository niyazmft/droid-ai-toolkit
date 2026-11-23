package dev.droidai.launcher

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
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
                title = "Auto-start OpenClaw gateway",
                subtitle = "Restart the gateway if it is down when the supervisor checks.",
                checked = autoStart,
                enabled = true,
            ) { Prefs.setAutoStart(it) }
            Fact(
                "Boot restore",
                when (snapshot?.termux?.bootInstalled) {
                    true -> "installed"
                    false -> "missing"
                    null -> "unknown"
                },
            )
            Text(
                "Boot restore is written by the engine (SERVICES → PM2).",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            TextButton(onClick = onRefresh, enabled = !running) { Text("Re-read status") }
        }

        Section("Termux & Safety")
        Panel {
            Fact("Command permission", if (Gate.permissionGranted.value) "granted" else "not granted")
            Fact("Termux", snapshot?.termux?.version ?: "—")
            TextButton(onClick = onRecheckPermission) { Text("Re-check") }
            SwitchRow(
                title = "Confirm before Remove…",
                subtitle = "Ask before deleting a venv, checkout or shims.",
                checked = confirmRemove,
                enabled = true,
            ) { Prefs.setConfirmRemove(it) }
            SwitchRow(
                title = "Retain raw command output",
                subtitle = "Keep the last run's stdout for troubleshooting.",
                checked = retainRaw,
                enabled = true,
            ) { Prefs.setRetainRaw(it) }
        }

        Section("Cleanup")
        Panel {
            Text(
                "Delete the old shared pnpm project (global/5) and the shims that point into it. " +
                    "Refused unless every tool is installed under tools/.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            TextButton(
                onClick = { confirmCleanup = true },
                enabled = !running,
            ) { Text("Remove legacy pnpm project", color = MaterialTheme.colorScheme.error) }
        }
    }

    if (confirmCleanup) {
        AlertDialog(
            onDismissRequest = { confirmCleanup = false },
            title = { Text("Remove legacy pnpm project?") },
            text = {
                Text(
                    "This deletes ~/.local/share/pnpm/global and the binaries that reference " +
                        "it. Tools already migrated to tools/ are unaffected. This cannot be undone.",
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

@Composable
private fun SwitchRow(
    title: String,
    subtitle: String,
    checked: Boolean,
    enabled: Boolean,
    onChange: (Boolean) -> Unit,
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyMedium)
            Text(
                subtitle,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Switch(checked = checked, onCheckedChange = onChange, enabled = enabled)
    }
}

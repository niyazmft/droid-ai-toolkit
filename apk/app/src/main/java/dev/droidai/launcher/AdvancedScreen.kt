package dev.droidai.launcher

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp

/**
 * Everything technical, one tap deeper than Settings.
 *
 * The Overview used to be a developer console: an eleven-row device table (`aarch64`, `API 29`,
 * "Swap free", "Boot restore"), a per-service Stop/Restart list, a Security panel containing an
 * `adb shell pm revoke` command, and a raw-output button — all on the first screen a
 * non-technical user sees. None of it is deleted (F3.1: raw output is kept, not dropped); it
 * lives here, labelled Advanced, behind Settings.
 *
 * ## Rules this screen follows
 *
 * - **Every jargon fact carries a plain subtitle** (F27): "arch — how the phone's processor is
 *   built". A row whose meaning needs a manual is a row that should explain itself.
 * - **Versions are shown in full.** This is the screen you come to when you are comparing what
 *   you have with what upstream released, so a shortened `0.119.0` would be the wrong answer
 *   here — that shortening belongs on a Home-adjacent fact row.
 * - **Nothing here runs on open.** Every action is a button, so scrolling through Advanced
 *   never costs a command.
 */
@Composable
fun AdvancedScreen(
    snapshot: Protocol.Snapshot?,
    services: List<Protocol.Service>,
    foreign: List<String>,
    accessAllowed: Boolean,
    running: Boolean,
    onBack: () -> Unit,
    onRestartService: (String) -> Unit,
    onStopService: (String) -> Unit,
    onRestartEverything: () -> Unit,
    onCheckAgain: () -> Unit,
    onOpenRawOutput: () -> Unit,
) {
    Column(
        Modifier
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Row(Modifier.padding(bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.advanced_advanced), style = MaterialTheme.typography.headlineMedium)
        }

        // ---- About this phone -----------------------------------------------------------
        Section(stringResource(R.string.advanced_about_this_phone))
        Panel {
            snapshot?.let { snap ->
                Fact("Model", snap.device.model)
                Fact("Android", "${snap.device.android} · API ${snap.device.api}")
                Fact("Architecture", snap.device.arch, spoken = "architecture: how this phone's processor is built")
                Text(
                    stringResource(R.string.advanced_arch_how_this_phone_s_processor),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Fact("Memory", "${snap.device.memAvailableMb} / ${snap.device.memTotalMb} MB")
                Text(
                    stringResource(R.string.advanced_memory_how_much_ram_is_free),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Fact("Swap", "${snap.device.swapFreeMb} MB free")
                Fact("Storage", "${snap.device.diskFreeMb / 1024} GB free")
                Text(
                    stringResource(R.string.advanced_storage_space_left_for_tools_and),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                // The full version string: this is the screen that answers "which build?".
                Fact("Termux", snap.termux.version)
                Fact("Node", Format.toolVersion(snap.tools.node))
                Fact("Python", Format.toolVersion(snap.tools.python))
                Fact(
                    "PM2",
                    if (snap.tools.pm2Installed) {
                        stringResource(
                            R.string.advanced_installed,
                        )
                    } else {
                        stringResource(R.string.advanced_missing)
                    },
                )
                Text(
                    stringResource(R.string.advanced_pm2_the_process_manager_that_keeps),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (snap.tools.openclaw.isNotBlank()) Fact("OpenClaw", Format.toolVersion(snap.tools.openclaw))
                if (snap.tools.hermes.isNotBlank()) FactLong("Hermes", Format.toolVersion(snap.tools.hermes))
                if (snap.tools.n8n.isNotBlank()) Fact("n8n", Format.toolVersion(snap.tools.n8n))
            }
            if (snapshot == null) {
                Text(
                    stringResource(R.string.advanced_reading_device_status),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        // ---- Background apps ------------------------------------------------------------
        Section(stringResource(R.string.advanced_background_apps))
        Panel {
            if (services.isEmpty()) {
                Text(
                    stringResource(R.string.advanced_nothing_is_running_choose_a_tool),
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            services.forEach { sv ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        sv.name,
                        style = MaterialTheme.typography.titleSmall,
                        modifier = Modifier.weight(1f),
                    )
                    StatusChip(sv.status == "online")
                }
                Text(
                    stringResource(R.string.advanced_mb_restarts, sv.memMb, sv.restarts),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.End)) {
                    UiPill(
                        label = stringResource(R.string.advanced_stop),
                        enabled = !running,
                        ghost = true,
                        onClick = { onStopService(sv.name) },
                    )
                    UiPill(
                        label = stringResource(R.string.advanced_restart),
                        enabled = !running,
                        ghost = true,
                        onClick = { onRestartService(sv.name) },
                    )
                }
            }
            if (services.isNotEmpty()) {
                UiPill(
                    label = stringResource(R.string.advanced_restart_everything),
                    enabled = !running,
                    onClick = onRestartEverything,
                )
            }
        }

        // ---- Termux & safety ------------------------------------------------------------
        Section(stringResource(R.string.advanced_termux_safety))
        Panel {
            Text(
                if (accessAllowed) {
                    "This app may run commands in Termux. That is how it installs and watches your tools."
                } else {
                    "This app may not run commands in Termux yet, so nothing can be installed."
                },
                style = MaterialTheme.typography.bodySmall,
            )
            if (foreign.isNotEmpty()) {
                Text(
                    stringResource(R.string.advanced_other_app_s_can_also_run, foreign.size),
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodySmall,
                )
                UiCodeBlock(foreign.joinToString("\n"))
                // The adb line is the remedy for an advanced user, not the message: a
                // non-technical reader needs the sentence, not the command.
                Text(
                    stringResource(R.string.advanced_if_you_did_not_install_one),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                UiCodeBlock(foreign.joinToString("\n") { Security.revokeCommand(it) })
            } else {
                Text(
                    stringResource(R.string.advanced_only_this_app_can_run_commands),
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            UiPill(label = stringResource(R.string.advanced_check_again), ghost = true, onClick = onCheckAgain)
        }

        // ---- Diagnostics ----------------------------------------------------------------
        Section(stringResource(R.string.advanced_diagnostics))
        Panel {
            Text(
                stringResource(R.string.advanced_everything_termux_printed_during_the_last),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            // The terminal glyph is the one place this icon belongs: it marks the screen that
            // is literally a terminal's output. (It was drawn and never used — F30.)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    TerminalIcon,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.width(6.dp))
                UiPill(
                    label = stringResource(R.string.advanced_open_raw_output),
                    ghost = true,
                    onClick = onOpenRawOutput,
                )
            }
        }

        // ---- Usage (was a top-level tab: a chart nobody asked for, on the first screen) ----
        Section(stringResource(R.string.advanced_usage))
        Panel {
            Text(
                stringResource(R.string.advanced_memory_and_swap_over_the_last),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        MetricsScreen(snapshot = snapshot)

        TextButton(onClick = onBack, modifier = Modifier.padding(top = 8.dp)) {
            Text(stringResource(R.string.advanced_back_to_settings))
        }
    }
}

package dev.droidai.launcher

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp

/**
 * "About this phone": the device facts, and what it has been doing.
 *
 * ## Why this is its own screen
 *
 * These sixteen rows used to be the first panel of **Advanced**, which meant a reader had to
 * open Settings (app preferences) to find out what phone they are holding. They are not
 * settings: nothing here can be changed, and the values are read, not chosen. The entry point is
 * now the phone name in the header — the line that already says which device this is — which is
 * where the question "which phone is this?" is actually asked.
 *
 * ## Rules kept from Advanced
 *
 * - **Every jargon fact carries a plain subtitle** (F27): "arch — how the phone's processor is
 *   built". A row whose meaning needs a manual is a row that should explain itself.
 * - **Versions are shown in full.** This is the screen you come to when comparing what you have
 *   with what upstream released, so a shortened `0.119.0` would be the wrong answer here; the
 *   shortening belongs on the Settings fact row.
 * - **Nothing here runs on open.** Opening it costs no command.
 */
@Composable
fun PhoneScreen(
    snapshot: Protocol.Snapshot?,
    onBack: () -> Unit,
) {
    Column(
        Modifier
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(stringResource(R.string.phone_about_this_phone), style = MaterialTheme.typography.headlineMedium)

        Section(stringResource(R.string.phone_device))
        Panel {
            if (snapshot == null) {
                Text(
                    stringResource(R.string.advanced_reading_device_status),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            } else {
                val snap = snapshot
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
            }
        }

        Section(stringResource(R.string.phone_installed_software))
        Panel {
            snapshot?.let { snap ->
                // The full version string: this is the screen that answers "which build?".
                Fact("Termux", snap.termux.version)
                Fact("Node", Format.toolVersion(snap.tools.node))
                Fact("Python", Format.toolVersion(snap.tools.python))
                Fact(
                    "PM2",
                    if (snap.tools.pm2Installed) {
                        stringResource(R.string.advanced_installed)
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

        // Memory and swap history belong with the device facts: they are measurements of this
        // phone, not preferences, and this is the screen a person opens to answer "why does it
        // keep stopping my tools?".
        Section(stringResource(R.string.phone_memory_over_time))
        PhoneUsage(snapshot = snapshot)

        TextButton(onClick = onBack, modifier = Modifier.padding(top = 8.dp)) {
            Text(stringResource(R.string.phone_back))
        }
    }
}

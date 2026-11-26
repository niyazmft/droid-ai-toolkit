package dev.droidai.launcher

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
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
import androidx.compose.ui.res.stringResource
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
    foreign: List<String> = emptyList(),
    onCheckAgain: () -> Unit = {},
    onOpenRawOutput: () -> Unit = {},
    onBack: () -> Unit = {},
    onTestBoot: () -> Unit = {},
    onOpenBootApp: () -> Unit = {},
) {
    val context = LocalContext.current
    val autoStart by Prefs.autoStartGateway.collectAsStateWithLifecycle()
    val supervisorOn by Prefs.supervisorEnabled.collectAsStateWithLifecycle()
    val confirmRemove by Prefs.confirmRemove.collectAsStateWithLifecycle()
    val retainRaw by Prefs.retainRaw.collectAsStateWithLifecycle()
    val themeMode by Prefs.themeMode.collectAsStateWithLifecycle()
    val bootTestedAt by Prefs.bootTestedAt.collectAsStateWithLifecycle()
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
        Text(stringResource(R.string.settings_settings), style = MaterialTheme.typography.headlineMedium)
        TextButton(onClick = onBack, modifier = Modifier.padding(top = 2.dp)) {
            Text(stringResource(R.string.settings_back))
        }

        Section(stringResource(R.string.settings_startup_services))
        Panel {
            // Copy per PLAN.md §F3.2: a 230-character subtitle was five lines of prose for a
            // switch. These are ≤ 26 / ≤ 85 chars so each row fits two lines at font scale 1.3.
            SwitchRow(
                title = stringResource(R.string.settings_watch_in_background),
                subtitle = stringResource(R.string.settings_one_notification_checked_when_you_unlock),
                checked = supervisorOn,
            ) { Prefs.setSupervisorEnabled(it) }
            // The grant is not optional: without it Android hides the notification while the
            // service keeps running, which is the one failure mode with no visible symptom.
            if (supervisorOn && !notificationsGranted) {
                Text(
                    stringResource(R.string.settings_notifications_are_off_so_a_stopped),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.error,
                )
                UiPill(
                    label = stringResource(R.string.settings_turn_on_notifications),
                    ghost = true,
                    onClick = onRequestNotifications,
                )
            }
            // The old label promised the wrong scope and the wrong condition: the toggle runs
            // `service.resurrect` → `pm2 resurrect`, which restores *every* process in the dump,
            // and it only fires when *nothing* is online (SupervisorPolicy returns HEALTHY as
            // soon as one service is up). One service, not all; stopped, not all-stopped.
            SwitchRow(
                title = stringResource(R.string.settings_restart_if_all_stop),
                subtitle = stringResource(R.string.settings_when_every_service_is_offline_try),
                checked = autoStart,
                // Disabled, not hidden: it can have no effect while nothing is watching, and a
                // tappable switch that does nothing advertises something the app is not doing.
                enabled = supervisorOn,
            ) { Prefs.setAutoStart(it) }
            // F6: a state block, not a fact. "Starts after reboot — set up" only proved the
            // Termux:Boot *app* was installed; it could read "set up" with no boot script and no
            // saved process list, which is a phone that comes back to nothing.
            BootStateBlock(
                snapshot = snapshot,
                running = running,
                testedAt = bootTestedAt,
                onRunAction = onRunAction,
                onTestBoot = onTestBoot,
                onOpenBootApp = onOpenBootApp,
            )
            UiPill(
                label = stringResource(R.string.settings_re_read_status),
                enabled = !running,
                ghost = true,
                onClick = onRefresh,
            )
        }

        Section(stringResource(R.string.settings_termux_safety))
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
            UiPill(label = stringResource(R.string.settings_check_again), ghost = true, onClick = onRecheckPermission)
            // Moved from Advanced: this is the one place that answers "who else can run
            // commands in Termux", so the warning and the re-check belong on the same panel.
            if (foreign.isNotEmpty()) {
                Text(
                    stringResource(R.string.advanced_other_app_s_can_also_run, foreign.size),
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodySmall,
                )
                UiCodeBlock(foreign.joinToString("\n"))
                Text(
                    stringResource(R.string.advanced_if_you_did_not_install_one),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                UiCodeBlock(foreign.joinToString("\n") { Security.revokeCommand(it) })
            }
            SwitchRow(
                title = stringResource(R.string.settings_ask_before_removing),
                subtitle = stringResource(R.string.settings_confirm_before_deleting_a_tool_its),
                checked = confirmRemove,
            ) { Prefs.setConfirmRemove(it) }
            SwitchRow(
                title = stringResource(R.string.settings_keep_the_last_command_output),
                subtitle = stringResource(R.string.settings_useful_when_asking_for_help_it),
                checked = retainRaw,
            ) { Prefs.setRetainRaw(it) }
        }

        Section(stringResource(R.string.settings_diagnostics))
        Panel {
            Text(
                stringResource(R.string.settings_diagnostics_what_termux_printed),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
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

        // Appearance last: it is the setting people change once, and it used to sit above
        // everything they change often.
        Section(stringResource(R.string.settings_appearance))
        Panel {
            Text(
                stringResource(R.string.settings_both_palettes_are_designed_this_only),
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

        Section(stringResource(R.string.settings_droid_ai))
        Panel {
            // No package name: it is the same app the reader is holding, and a dotted
            // `dev.droidai.launcher` is the kind of row people scroll past to reach the version.
            Fact("Version", APP_VERSION)
        }

        // Hidden entirely when the legacy folder is absent, which is the normal state on a
        // device that has migrated: showing a button that removes nothing and then reports
        // "done" is how 8x claimed a successful cleanup of a folder that was already gone.
        if (snapshot?.termux?.legacyGlobalPresent == true) {
            val migrated = snapshot.checks["tools_migrated"] != false
            val mb = snapshot.termux.legacyGlobalMb
            Section(stringResource(R.string.settings_cleanup))
            Panel {
                val size =
                    when {
                        mb >= 1024 -> String.format(java.util.Locale.US, "%.1f GB", mb / 1024.0)
                        mb > 0 -> "$mb MB"
                        else -> "size not measured yet"
                    }
                Text(
                    stringResource(R.string.settings_legacy_package_folder, size),
                    style = MaterialTheme.typography.titleSmall,
                )
                Text(
                    if (migrated) {
                        "Left behind by an earlier version. Nothing uses it now, so it can be removed."
                    } else {
                        // The engine's own refusal, said before the tap. It used to arrive after
                        // it, as "Step failed: Remove legacy project and shims".
                        "Still in use: a tool has not been moved to its own folder yet. Open Tools and update it first."
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                UiPill(
                    label = stringResource(R.string.settings_remove_it),
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
            title = { Text(stringResource(R.string.settings_remove_the_old_package_folder)) },
            text = {
                Text(
                    stringResource(R.string.settings_this_deletes_the_legacy_shared_pnpm),
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmCleanup = false
                    onRunAction("service.cleanup-legacy")
                }) { Text(stringResource(R.string.settings_remove)) }
            },
            dismissButton = {
                TextButton(onClick = { confirmCleanup = false }) { Text(stringResource(R.string.settings_cancel)) }
            },
        )
    }
}

/**
 * "Will my services come back after a reboot?" — answered by three checks and one button.
 *
 * The old row answered it with one fact that only proved the Termux:Boot app was installed.
 * Three things actually have to be true:
 *
 *   1. the Termux:Boot app is installed and allowed to start on boot (the toolkit cannot do it);
 *   2. a boot script exists in `~/.termux/boot/` and is executable (the toolkit writes it);
 *   3. `pm2 save` has recorded a process list with something in it (the toolkit can run it).
 *
 * Each state shows exactly one button, and the last one says "not yet tested" until a reboot
 * has actually restored something — the app cannot observe a reboot it did not witness, and
 * claiming otherwise is how "set up" came to mean nothing.
 */
@Composable
private fun BootStateBlock(
    snapshot: Protocol.Snapshot?,
    running: Boolean,
    testedAt: Long = 0L,
    onRunAction: (String) -> Unit,
    onTestBoot: () -> Unit,
    onOpenBootApp: () -> Unit,
) {
    val termux = snapshot?.termux
    val script = termux?.bootScript == true
    val saved = termux?.pm2DumpCount ?: 0
    val appInstalled = termux?.bootInstalled == true

    val title: String
    val detail: String
    val label: String?
    val onClick: () -> Unit
    when {
        snapshot == null -> {
            title = "Starts after reboot"
            detail = "Reading what is in place…"
            label = null
            onClick = {}
        }
        !appInstalled -> {
            title = "Needs Termux:Boot"
            detail =
                "Android needs the Termux:Boot app to run anything at startup. Install it, open it once, then come back."
            label = "Get Termux:Boot"
            onClick = onOpenBootApp
        }
        !script || saved == 0 -> {
            title = "Set up after reboot"
            detail = "Writes the boot script and saves the process list."
            label = "Set up"
            onClick = { onRunAction("service.boot") }
        }
        !(termux?.dozeWhitelisted ?: false) -> {
            title = "Allow background start"
            detail =
                "Android may still stop Termux at boot. Allow Termux and Termux:Boot to run in the background (Settings → Apps → Battery)."
            label = "Check again"
            onClick = { onRunAction("service.boot") }
        }
        testedAt > 0L -> {
            // It still cannot claim a *reboot* worked — only that the restore the boot script
            // runs has. Saying which one is the difference between evidence and a slogan.
            title = "Works after reboot — tested ${Format.age(System.currentTimeMillis(), testedAt)}"
            detail = "The saved list was restored successfully the same way the boot script does it."
            label = "Test again"
            onClick = onTestBoot
        }
        else -> {
            title = "Works after reboot — not yet tested"
            // Honesty rule: nothing here has watched a reboot, so it cannot claim one worked.
            detail =
                "The script and the saved list are in place. Test now restores the saved list the same way the boot script does."
            label = "Test now"
            onClick = onTestBoot
        }
    }

    Text(title, style = MaterialTheme.typography.titleSmall)
    Text(
        detail,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    label?.let {
        UiPill(label = it, enabled = !running, ghost = true, onClick = onClick)
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
    val value =
        if (allowed) {
            stringResource(
                R.string.settings_allowed,
            )
        } else {
            stringResource(R.string.settings_not_allowed)
        }
    Row(
        Modifier
            .fillMaxWidth()
            .semantics(mergeDescendants = true) { contentDescription = "Access: $value" },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            stringResource(R.string.settings_access),
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

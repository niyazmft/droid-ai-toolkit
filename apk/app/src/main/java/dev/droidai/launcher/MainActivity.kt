package dev.droidai.launcher

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.List
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

class MainActivity : ComponentActivity() {
    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) {
            Gate.refresh(this)
            Gate.probeOk.value = null
            Termux.probe(this)
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Prefs.init(this)
        Gate.refresh(this)
        setContent {
            DroidTheme {
                Surface(Modifier.fillMaxSize()) { Root() }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        Gate.refresh(this)
    }

    private fun requestPermission() = permissionLauncher.launch(Termux.PERMISSION)

    private fun openUrl(url: String) {
        runCatching {
            startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse(url))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }

    @Composable
    private fun Root() {
        val termux by Gate.termuxInstalled.collectAsState()
        val permission by Gate.permissionGranted.collectAsState()
        val probe by Gate.probeOk.collectAsState()
        val message by Gate.probeMessage.collectAsState()
        val down by Gate.termuxUnresponsive.collectAsState()

        LaunchedEffect(termux, permission) {
            if (termux && permission && probe == null) Termux.probe(this@MainActivity)
        }

        // A lost result must not wedge the app: after 30 s the in-flight command is
        // abandoned so Retry can dispatch again.
        val busy by Runner.running.collectAsState()
        LaunchedEffect(busy) {
            if (busy) {
                kotlinx.coroutines.delay(30_000)
                if (Runner.running.value) Runner.timeout(30)
            }
        }

        when {
            !termux ->
                Setup(
                    title = "Termux is required",
                    body =
                        "Droid AI runs inside Termux, which owns the Linux environment. " +
                            "Install it from F-Droid or the GitHub releases — not the Play Store build, " +
                            "which is outdated.",
                    primary = "Get Termux" to { openUrl("https://f-droid.org/packages/com.termux/") },
                    secondary = "Re-check" to { Gate.refresh(this@MainActivity) },
                )

            !permission ->
                Setup(
                    title = "Allow commands in Termux",
                    body =
                        "Android needs you to grant \"Run commands in Termux environment\". " +
                            "It is a dangerous permission defined by Termux, so it appears under " +
                            "Additional permissions in App info.",
                    primary = "Grant permission" to { requestPermission() },
                    secondary = "Re-check" to { Gate.refresh(this@MainActivity) },
                )

            probe != true ->
                Setup(
                    title = if (down) "Termux isn't running" else "Enable external commands",
                    body =
                        if (down) {
                            "Android killed Termux's process (low memory), so it cannot run commands " +
                                "right now. Open Termux, then come back and retry.\n\n" +
                                "This is not the allow-external-apps setting — that one is already on."
                        } else {
                            "Termux only accepts commands from other apps when allow-external-apps " +
                                "is true. In Termux, run:\n\n" +
                                "echo \"allow-external-apps = true\" >> ~/.termux/termux.properties\n" +
                                "termux-reload-settings\n\n" +
                                "Then come back and retry." +
                                if (message.isNotBlank()) "\n\nReported: $message" else ""
                        },
                    primary = "Open Termux" to { Termux.openTermux(this@MainActivity) },
                    secondary =
                        "Retry" to {
                            Gate.probeOk.value = null
                            Termux.probe(this@MainActivity)
                        },
                )

            else -> Home()
        }
    }
}

@Composable
private fun Setup(
    title: String,
    body: String,
    primary: Pair<String, () -> Unit>,
    secondary: Pair<String, () -> Unit>,
) {
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(title, style = MaterialTheme.typography.headlineSmall)
        Text(body, style = MaterialTheme.typography.bodyMedium)
        Button(onClick = primary.second, modifier = Modifier.fillMaxWidth()) { Text(primary.first) }
        OutlinedButton(onClick = secondary.second, modifier = Modifier.fillMaxWidth()) {
            Text(secondary.first)
        }
    }
}

@Composable
internal fun Section(title: String) {
    Text(
        title,
        style = MaterialTheme.typography.titleMedium,
        modifier = Modifier.padding(top = 12.dp, bottom = 2.dp),
    )
}

@Composable
internal fun Fact(
    label: String,
    value: String,
) {
    if (value.isBlank()) return
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            label,
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.weight(1f),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        // A version string like "Hermes Agent vgit.707cf0f (2026.9.24) · stable · …"
        // must not wrap the row: one line each keeps the panel a table, not a paragraph.
        Text(
            value,
            style = MaterialTheme.typography.bodySmall,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1.4f),
            textAlign = TextAlign.End,
        )
    }
}

/** A rounded surface for one group of related rows. */
@Composable
internal fun Panel(content: @Composable ColumnScope.() -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
        colors =
            CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f),
            ),
    ) {
        Column(
            Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp),
            content = content,
        )
    }
}

@Composable
internal fun StatusChip(
    online: Boolean,
    label: String? = null,
) {
    val bg = if (online) Tokens.SuccessContainer else MaterialTheme.colorScheme.errorContainer
    val fg = if (online) Tokens.OnSuccessContainer else MaterialTheme.colorScheme.onErrorContainer
    Surface(color = bg, contentColor = fg, shape = RoundedCornerShape(50)) {
        Text(
            label ?: if (online) "online" else "stopped",
            style = MaterialTheme.typography.labelSmall,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
        )
    }
}

@Composable
private fun Placeholder(
    title: String,
    body: String,
) {
    Text(title, style = MaterialTheme.typography.headlineSmall, modifier = Modifier.padding(top = 8.dp))
    Text(body, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

private enum class Tab(
    val label: String,
) {
    OVERVIEW("Overview"),
    PACKAGES("Packages"),
    METRICS("Metrics"),
    SETTINGS("Settings"),
}

@Composable
private fun Home() {
    val context = LocalContext.current
    val result by Runner.result.collectAsState()
    val running by Runner.running.collectAsState()

    var snapshot by remember { mutableStateOf<Protocol.Snapshot?>(null) }
    var actions by remember { mutableStateOf<List<Protocol.Action>>(emptyList()) }
    var failure by remember { mutableStateOf<String?>(null) }
    var askedForActions by remember { mutableStateOf(false) }
    var showRaw by remember { mutableStateOf(false) }
    var raw by remember { mutableStateOf("") }
    var steps by remember { mutableStateOf<List<Protocol.Step>>(emptyList()) }
    var pending by remember { mutableStateOf<Protocol.Action?>(null) }
    var capacity by remember { mutableStateOf<Protocol.Action?>(null) }
    var foreign by remember { mutableStateOf(Security.foreignHolders(context)) }
    var tab by remember { mutableStateOf(Tab.OVERVIEW) }
    var showRawScreen by remember { mutableStateOf(false) }
    val confirmRemove by Prefs.confirmRemove.collectAsState()
    val retainRaw by Prefs.retainRaw.collectAsState()

    LaunchedEffect(Unit) {
        Runner.send(context, listOf("--api", "status"))
        // Foreground supervisor: keeps a low oom_score_adj and makes Termux's death
        // visible instead of silent. It cannot prevent an LMK kill.
        runCatching { SupervisorService.start(context) }
    }

    LaunchedEffect(result) {
        val r = result ?: return@LaunchedEffect
        raw = r.stdout
        steps = Protocol.finalSteps(r.stdout)

        if (r.exitCode != 0 || r.errmsg.isNotBlank()) {
            failure = Protocol.error(r.stdout, r.stderr, r.errmsg)
                ?: "Command failed (exit ${r.exitCode})"
            return@LaunchedEffect
        }
        failure = null

        // Route on the payload, not on which button was pressed: a probe result is still
        // in the StateFlow when the screen first composes, so responses can overlap.
        val catalog = Protocol.actions(r.stdout)
        if (catalog.isNotEmpty()) {
            actions = catalog
            return@LaunchedEffect
        }

        Protocol.snapshot(r.stdout)?.let { snapshot = it }
    }

    // Fetch the catalog once the device is idle. Keyed on `running` so the retry happens
    // after the previous command finishes, and only when the send really dispatched.
    LaunchedEffect(running, snapshot) {
        if (!running && snapshot != null && actions.isEmpty() && !askedForActions) {
            if (Runner.send(context, listOf("--api", "list"))) askedForActions = true
        }
    }

    Scaffold(
        bottomBar = {
            NavigationBar {
                Tab.values().forEach { t ->
                    NavigationBarItem(
                        selected = tab == t,
                        onClick = { tab = t },
                        icon = {
                            Icon(
                                when (t) {
                                    Tab.OVERVIEW -> Icons.Filled.List
                                    Tab.PACKAGES -> PackageIcon
                                    Tab.METRICS -> MetricsIcon
                                    Tab.SETTINGS -> Icons.Filled.Settings
                                },
                                contentDescription = t.label,
                            )
                        },
                        label = { Text(t.label) },
                    )
                }
            }
        },
    ) { pad ->
        if (showRawScreen) {
            Box(Modifier.padding(pad)) {
                RawOutputScreen(
                    raw = if (retainRaw) raw else "",
                    retained = retainRaw,
                    onBack = { showRawScreen = false },
                )
            }
            return@Scaffold
        }
        Column(
            Modifier
                .padding(pad)
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Droid AI", style = MaterialTheme.typography.headlineMedium)
                    Text(
                        snapshot?.let { "${it.device.model} · ${it.device.arch}" } ?: "Termux is ready.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                IconButton(
                    onClick = {
                        failure = null
                        Runner.send(context, listOf("--api", "status"))
                    },
                    enabled = !running,
                ) { Icon(Icons.Filled.Refresh, contentDescription = "Refresh") }
            }

            if (running) {
                LinearProgressIndicator(Modifier.fillMaxWidth().padding(vertical = 4.dp))
            }

            failure?.let {
                Text(
                    it,
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(vertical = 4.dp),
                )
            }

            when (tab) {
                Tab.OVERVIEW -> {
                    if (steps.isNotEmpty()) {
                        Section("Last run")
                        Panel {
                            steps.forEach { s ->
                                val mark =
                                    when (s.state) {
                                        "ok" -> "\u2714"
                                        "failed" -> "\u2716"
                                        "skipped" -> "\u2013"
                                        else -> "\u2026"
                                    }
                                val took = if (s.ms >= 1000) "  (${s.ms / 1000}s)" else ""
                                Text(
                                    "$mark ${s.title}$took",
                                    style = MaterialTheme.typography.bodySmall,
                                    color =
                                        if (s.state == "failed") {
                                            MaterialTheme.colorScheme.error
                                        } else {
                                            MaterialTheme.colorScheme.onSurface
                                        },
                                )
                            }
                        }
                    }

                    snapshot?.let { s ->
                        Section("Device")
                        Panel {
                            Fact("Model", s.device.model)
                            Fact("Android", "${s.device.android} · API ${s.device.api}")
                            Fact("Arch", s.device.arch)
                            Fact("Memory", "${s.device.memAvailableMb} MB free of ${s.device.memTotalMb} MB")
                            Fact("Swap free", "${s.device.swapFreeMb} MB")
                            Fact("Disk free", "${s.device.diskFreeMb / 1024} GB")
                            Fact("Termux", s.termux.version)
                            Fact("Boot restore", if (s.termux.bootInstalled) "installed" else "missing")
                            Fact("Node", s.tools.node)
                            Fact("Python", s.tools.python)
                            Fact("PM2", if (s.tools.pm2Installed) "installed" else "missing")
                            if (s.tools.openclaw.isNotBlank()) Fact("OpenClaw", s.tools.openclaw)
                            if (s.tools.hermes.isNotBlank()) Fact("Hermes", s.tools.hermes)
                            if (s.tools.n8n.isNotBlank()) Fact("n8n", s.tools.n8n)
                        }

                        Section("Services")
                        Panel {
                            if (s.services.isEmpty()) {
                                Text(
                                    "No PM2 services running.",
                                    style = MaterialTheme.typography.bodySmall,
                                )
                            }
                            s.services.forEach { sv ->
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(
                                        sv.name,
                                        style = MaterialTheme.typography.titleSmall,
                                        modifier = Modifier.weight(1f),
                                    )
                                    StatusChip(sv.status == "online")
                                }
                                Text(
                                    "${sv.memMb} MB · ${sv.restarts} restarts",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                    TextButton(
                                        onClick = {
                                            failure = null
                                            Runner.send(
                                                context,
                                                listOf(
                                                    "--api",
                                                    "run",
                                                    "service.stop",
                                                    "--arg",
                                                    "service=${sv.name}",
                                                ),
                                            )
                                        },
                                        enabled = !running,
                                    ) { Text("Stop", style = MaterialTheme.typography.labelLarge) }
                                    TextButton(
                                        onClick = {
                                            failure = null
                                            Runner.send(
                                                context,
                                                listOf(
                                                    "--api",
                                                    "run",
                                                    "service.restart",
                                                    "--arg",
                                                    "service=${sv.name}",
                                                ),
                                            )
                                        },
                                        enabled = !running,
                                    ) { Text("Restart", style = MaterialTheme.typography.labelLarge) }
                                }
                            }
                            Button(
                                onClick = {
                                    failure = null
                                    Runner.send(context, listOf("--api", "run", "service.resurrect"))
                                },
                                enabled = !running,
                                modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
                            ) { Text("Restart services") }
                        }
                    }

                    Section("Security")
                    Panel {
                        if (foreign.isEmpty()) {
                            Text(
                                "Only this app holds the Termux command permission.",
                                style = MaterialTheme.typography.bodySmall,
                            )
                        } else {
                            Text(
                                "${foreign.size} other app(s) can also run commands in Termux:",
                                color = MaterialTheme.colorScheme.error,
                                style = MaterialTheme.typography.bodySmall,
                            )
                            foreign.forEach { pkg ->
                                Text(
                                    pkg,
                                    fontFamily = FontFamily.Monospace,
                                    style = MaterialTheme.typography.bodySmall,
                                )
                            }
                            Text(
                                "Revoke with:\n" + foreign.joinToString("\n") { Security.revokeCommand(it) },
                                fontFamily = FontFamily.Monospace,
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                        TextButton(onClick = { foreign = Security.foreignHolders(context) }) {
                            Text("Re-check", style = MaterialTheme.typography.labelLarge)
                        }
                    }

                    TextButton(onClick = { showRawScreen = true }) {
                        Text("Show raw output")
                    }
                }

                Tab.PACKAGES ->
                    PackagesScreen(
                        snapshot = snapshot,
                        actions = actions,
                        running = running,
                        onRun = { action ->
                            val short =
                                snapshot?.let {
                                    (action.minMemMb > 0 && it.device.memAvailableMb < action.minMemMb) ||
                                        (action.minDiskMb > 0 && it.device.diskFreeMb < action.minDiskMb)
                                } ?: false

                            when {
                                action.destructive && confirmRemove -> pending = action
                                action.destructive -> {
                                    failure = null
                                    Runner.send(context, listOf("--api", "run", action.id, "--yes"))
                                }
                                short -> capacity = action
                                else -> {
                                    failure = null
                                    Runner.send(context, listOf("--api", "run", action.id))
                                }
                            }
                        },
                    )

                Tab.METRICS -> MetricsScreen(snapshot = snapshot)

                Tab.SETTINGS ->
                    SettingsScreen(
                        snapshot = snapshot,
                        running = running,
                        onRefresh = {
                            failure = null
                            Runner.send(context, listOf("--api", "status"))
                        },
                        onRecheckPermission = {
                            Gate.refresh(context)
                            Gate.probeOk.value = null
                            Termux.probe(context)
                        },
                        onRunAction = { id ->
                            failure = null
                            Runner.send(context, listOf("--api", "run", id, "--yes"))
                        },
                    )
            }
        }
    }

    capacity?.let { a ->
        val snap = snapshot
        AlertDialog(
            onDismissRequest = { capacity = null },
            title = { Text("This device may not fit ${a.title}") },
            text = {
                Text(
                    (
                        if (a.minMemMb > 0) {
                            "${a.title} asks for ${a.minMemMb} MB free memory; this device has " +
                                "${snap?.device?.memAvailableMb ?: 0} MB.\n\n"
                        } else {
                            ""
                        }
                    ) +
                        (
                            if (a.minDiskMb > 0) {
                                "It asks for ${a.minDiskMb} MB free storage; this device has " +
                                    "${snap?.device?.diskFreeMb ?: 0} MB.\n\n"
                            } else {
                                ""
                            }
                        ) +
                        "Installing anyway usually ends with Android killing it part-way. " +
                        "Close something and tap Refresh first, or continue at your own risk.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    capacity = null
                    failure = null
                    Runner.send(context, listOf("--api", "run", a.id))
                }) { Text("Install anyway") }
            },
            dismissButton = {
                TextButton(onClick = { capacity = null }) { Text("Cancel") }
            },
        )
    }

    pending?.let { a ->
        AlertDialog(
            onDismissRequest = { pending = null },
            title = { Text(a.title) },
            text = { Text(a.summary + "\n\nThis cannot be undone.") },
            confirmButton = {
                TextButton(onClick = {
                    pending = null
                    failure = null
                    // The engine refuses destructive specs without this flag.
                    Runner.send(context, listOf("--api", "run", a.id, "--yes"))
                }) { Text("Confirm") }
            },
            dismissButton = {
                TextButton(onClick = { pending = null }) { Text("Cancel") }
            },
        )
    }
}

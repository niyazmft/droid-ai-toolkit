package dev.droidai.launcher

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
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
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
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
        Gate.refresh(this)
        setContent {
            MaterialTheme {
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
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
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
            !termux -> Setup(
                title = "Termux is required",
                body = "Droid AI runs inside Termux, which owns the Linux environment. " +
                    "Install it from F-Droid or the GitHub releases — not the Play Store build, " +
                    "which is outdated.",
                primary = "Get Termux" to { openUrl("https://f-droid.org/packages/com.termux/") },
                secondary = "Re-check" to { Gate.refresh(this@MainActivity) }
            )

            !permission -> Setup(
                title = "Allow commands in Termux",
                body = "Android needs you to grant \"Run commands in Termux environment\". " +
                    "It is a dangerous permission defined by Termux, so it appears under " +
                    "Additional permissions in App info.",
                primary = "Grant permission" to { requestPermission() },
                secondary = "Re-check" to { Gate.refresh(this@MainActivity) }
            )

            probe != true -> Setup(
                title = if (down) "Termux isn't running" else "Enable external commands",
                body = if (down) {
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
                secondary = "Retry" to {
                    Gate.probeOk.value = null
                    Termux.probe(this@MainActivity)
                }
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
    secondary: Pair<String, () -> Unit>
) {
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
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
private fun Section(title: String) {
    Text(
        title,
        style = MaterialTheme.typography.titleMedium,
        modifier = Modifier.padding(top = 12.dp)
    )
}

@Composable
private fun Fact(label: String, value: String) {
    if (value.isBlank()) return
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(label, style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f))
        Text(value, style = MaterialTheme.typography.bodySmall)
    }
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
    var foreign by remember { mutableStateOf(Security.foreignHolders(context)) }

    LaunchedEffect(Unit) {
        Runner.send(context, listOf("--api", "status"))
        // Foreground supervisor: keeps a low oom_score_adj and makes Termux's death
        // visible instead of silent. It cannot prevent an LMK kill.
        runCatching { SupervisorService.start(context) }
    }

    LaunchedEffect(result) {
        val r = result ?: return@LaunchedEffect
        raw = r.stdout
        steps = Protocol.steps(r.stdout)

        if (r.exitCode != 0 || r.errmsg.isNotBlank()) {
            failure = Protocol.error(r.stdout, r.stderr, r.errmsg)
                ?: "Command failed (exit ${r.exitCode})"
            return@LaunchedEffect
        }
        failure = null

        // Route on the payload, not on which button was pressed. Commands overlap
        // (a probe result is still in the StateFlow when Home first composes), and
        // the old `mode` flag let a late status response clear a catalog that had
        // already arrived — which is why Actions sometimes rendered nothing.
        val catalog = Protocol.actions(r.stdout)
        if (catalog.isNotEmpty()) {
            actions = catalog
            return@LaunchedEffect
        }

        Protocol.snapshot(r.stdout)?.let { snapshot = it }
    }

    // Fetch the catalog once the device is idle. Keyed on `running` so the retry
    // happens after the previous command finishes, and the flag is only set when
    // the send really dispatched (a dropped request must be retried, not assumed).
    LaunchedEffect(running, snapshot) {
        if (!running && snapshot != null && actions.isEmpty() && !askedForActions) {
            if (Runner.send(context, listOf("--api", "list"))) askedForActions = true
        }
    }

    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp)
    ) {
        Text("Droid AI", style = MaterialTheme.typography.headlineMedium)
        Text(
            snapshot?.let { "${it.device.model} · ${it.device.arch}" } ?: "Termux is ready.",
            style = MaterialTheme.typography.bodyMedium
        )

        Row(
            Modifier.padding(vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Button(
                onClick = {
                    failure = null
                    Runner.send(context, listOf("--api", "status"))
                },
                enabled = !running
            ) { Text("Refresh") }

            OutlinedButton(
                onClick = {
                    failure = null
                    askedForActions = true
                    Runner.send(context, listOf("--api", "list"))
                },
                enabled = !running
            ) { Text("Actions") }
        }

        if (running) {
            LinearProgressIndicator(Modifier.fillMaxWidth())
            Text("Working…", style = MaterialTheme.typography.bodySmall)
        }

        failure?.let {
            Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
        }

        if (steps.isNotEmpty()) {
            Section("Last run")
            steps.forEach { s ->
                val mark = when (s.state) {
                    "ok" -> "\u2714"
                    "failed" -> "\u2716"
                    "skipped" -> "\u2013"
                    else -> "\u2026"
                }
                val took = if (s.ms >= 1000) "  (${s.ms / 1000}s)" else ""
                Text(
                    "$mark ${s.title}$took",
                    style = MaterialTheme.typography.bodySmall,
                    color = if (s.state == "failed") MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface
                )
            }
        }

        snapshot?.let { s ->
            Section("Device")
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

            Section("Services")
            if (s.services.isEmpty()) {
                Text("No PM2 services running.", style = MaterialTheme.typography.bodySmall)
            } else {
                s.services.forEach { sv ->
                    Fact(sv.name, "${sv.status} · ${sv.memMb} MB · ${sv.restarts} restarts")
                }
            }
        }

        if (actions.isNotEmpty()) {
            Section("Actions")
            actions.forEach { a ->
                Text(a.title, style = MaterialTheme.typography.titleSmall)
                Text(a.summary, style = MaterialTheme.typography.bodySmall)
                TextButton(
                    onClick = {
                        if (a.destructive) {
                            pending = a
                        } else {
                            failure = null
                            Runner.send(context, listOf("--api", "run", a.id))
                        }
                    },
                    enabled = !running
                ) { Text(if (a.destructive) "Remove…" else "Run") }
            }
        }

        // allow-external-apps is one global boolean; the permission grant is the
        // only real boundary, so name every other holder rather than assume none.
        Section("Security")
        if (foreign.isEmpty()) {
            Text(
                "Only this app holds the Termux command permission.",
                style = MaterialTheme.typography.bodySmall
            )
        } else {
            Text(
                "${foreign.size} other app(s) can also run commands in Termux:",
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodySmall
            )
            foreign.forEach { pkg ->
                Text(pkg, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
            }
            Text(
                "Revoke with:\n" + foreign.joinToString("\n") { Security.revokeCommand(it) },
                fontFamily = FontFamily.Monospace,
                style = MaterialTheme.typography.bodySmall
            )
        }
        TextButton(onClick = { foreign = Security.foreignHolders(context) }) { Text("Re-check") }

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
                }
            )
        }

        TextButton(onClick = { showRaw = !showRaw }) {
            Text(if (showRaw) "Hide raw output" else "Show raw output")
        }
        if (showRaw) {
            Text(
                raw.take(20000),
                fontFamily = FontFamily.Monospace,
                style = MaterialTheme.typography.bodySmall
            )
        }
    }
}

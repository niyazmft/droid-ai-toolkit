package dev.droidai.launcher

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
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
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay

class MainActivity : ComponentActivity() {
    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) {
            Gate.refresh(this)
            Termux.probe(this)
        }

    /** Set once a probe has failed, so returning from Termux re-checks by itself. */
    private var recheckOnResume = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Prefs.init(this)
        Runner.attach(this)
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
        // Coming back from Termux, or from the system permission dialog, is the moment
        // the user has just done what we asked. Re-check automatically instead of
        // making them find a "Retry" button and press it.
        if (recheckOnResume && Gate.termuxInstalled.value && Gate.permissionGranted.value) {
            recheckOnResume = false
            Termux.probe(this)
        }
    }

    private fun markRecheck() {
        recheckOnResume = true
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
        val probe by Gate.probe.collectAsState()
        val detail by Gate.detail.collectAsState()
        val readyBefore by Prefs.termuxReady.collectAsState()

        LaunchedEffect(termux, permission) {
            if (termux && permission && probe == Probe.CHECKING && !Runner.running.value) {
                Termux.probe(this@MainActivity)
            }
        }

        when {
            !termux ->
                Setup(
                    title = "Install Termux first",
                    body =
                        "Droid AI runs your AI tools inside Termux, a small Linux environment for " +
                            "Android. Think of Termux as the engine and this app as its dashboard.",
                    note =
                        "Install the F-Droid version, not the one from the Play Store — the Play " +
                            "Store copy is out of date and the app cannot work with it.",
                    primary = "Get Termux (F-Droid)" to { openUrl("https://f-droid.org/packages/com.termux/") },
                    secondary = "I already installed it" to { Gate.refresh(this@MainActivity) },
                )

            !permission ->
                Setup(
                    title = "Allow Droid AI to control Termux",
                    body =
                        "Android asks you to confirm that this app may start commands inside " +
                            "Termux. Without it the app cannot read your device status or install " +
                            "anything.",
                    note = "Nothing is downloaded or changed until you choose to install a tool.",
                    primary = "Allow" to { requestPermission() },
                    secondary = "Check again" to { Gate.refresh(this@MainActivity) },
                )

            probe == Probe.CHECKING ->
                // A device that has worked before goes straight to the Overview while the
                // probe runs — the gate screens are for first-time setup, not for every
                // launch. Anything that is genuinely wrong demotes the flag in
                // Runner.classify() and the gate reappears during this same run.
                if (readyBefore) Home() else Checking()

            probe == Probe.READY -> Home()

            probe == Probe.DENIED ->
                Setup(
                    title = "One-time setup in Termux",
                    body =
                        "Termux ignores commands from other apps until you allow them. That is a " +
                            "safety feature protecting your shell — it is not a fault in this app, " +
                            "and it is the only step it cannot do for you.\n\n" +
                            "Copy the line below, paste it into Termux, and press Enter. You only " +
                            "do this once.",
                    code = Termux.ALLOW_EXTERNAL_APPS,
                    note =
                        "Then come back here — the app checks again by itself.\n\n" +
                            "If you already ran that line and Termux is still refusing it, Termux has " +
                            "not reloaded its settings yet: swipe Termux away from your recent apps, " +
                            "then tap Check again.",
                    primary =
                        "Copy the line and open Termux" to {
                            markRecheck()
                            Termux.openTermux(this@MainActivity)
                        },
                    secondary =
                        "Check again" to {
                            Gate.refresh(this@MainActivity)
                            Termux.probe(this@MainActivity)
                        },
                    detail = detail,
                )

            probe == Probe.NO_TOOLKIT ->
                Setup(
                    title = "Setup did not finish",
                    body =
                        "Droid AI could not download its toolkit into Termux. This needs a working " +
                            "internet connection the first time.",
                    note = "Check Wi-Fi or mobile data, then try again. Nothing on your device was changed.",
                    primary =
                        "Try again" to {
                            Gate.refresh(this@MainActivity)
                            Termux.probe(this@MainActivity)
                        },
                    secondary = "Open Termux" to { Termux.openTermux(this@MainActivity) },
                    detail = detail,
                )

            probe == Probe.UNREACHABLE ->
                Setup(
                    title = "Termux is not responding",
                    body =
                        "Android stopped Termux to free memory, so it cannot run commands right " +
                            "now. This is not a settings problem — Termux just needs to be running.",
                    note = "Open Termux once, then come back. Keeping this app open in the background helps.",
                    primary =
                        "Open Termux" to {
                            markRecheck()
                            Termux.openTermux(this@MainActivity)
                        },
                    secondary =
                        "Try again" to {
                            Gate.refresh(this@MainActivity)
                            Termux.probe(this@MainActivity)
                        },
                    detail = detail,
                )

            else ->
                Setup(
                    title = "Something went wrong",
                    body = "The app reached Termux, but it did not answer as expected.",
                    primary =
                        "Try again" to {
                            Gate.refresh(this@MainActivity)
                            Termux.probe(this@MainActivity)
                        },
                    secondary = "Open Termux" to { Termux.openTermux(this@MainActivity) },
                    detail = detail,
                )
        }
    }

    /**
     * A neutral "we are still finding out" screen.
     *
     * The first status run takes up to ten seconds on a phone. Before this existed the
     * app rendered the *failure* screen for that whole time, so every launch opened on
     * a red-looking page telling the user to edit Termux's settings — which were
     * already correct.
     */
    @Composable
    private fun Checking() {
        Column(
            Modifier.fillMaxSize().padding(32.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            CircularProgressIndicator()
            Text("Checking your device…", style = MaterialTheme.typography.titleMedium)
            Text(
                "Reading Termux and the tools you already have.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }
    }
}

/**
 * One onboarding screen: what is happening, why, and exactly one obvious thing to do.
 *
 * [code] exists because the single unavoidable Termux step is pasting a line, and asking
 * a non-technical user to type it by hand is where they give up. [detail] keeps the
 * engine's raw diagnosis available without putting `exit=4 err=-1` in front of someone
 * who cannot act on it.
 */
@Composable
private fun Setup(
    title: String,
    body: String,
    primary: Pair<String, () -> Unit>,
    secondary: Pair<String, () -> Unit>,
    note: String? = null,
    code: String? = null,
    detail: String = "",
) {
    val clipboard = LocalClipboardManager.current
    var showDetail by rememberSaveable { mutableStateOf(false) }
    var copied by remember { mutableStateOf(false) }

    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(title, style = MaterialTheme.typography.headlineSmall)
        Text(body, style = MaterialTheme.typography.bodyMedium)

        code?.let {
            Panel {
                Text(
                    it,
                    fontFamily = FontFamily.Monospace,
                    style = MaterialTheme.typography.bodySmall,
                )
                TextButton(
                    onClick = {
                        clipboard.setText(AnnotatedString(it))
                        copied = true
                    },
                    modifier = Modifier.heightIn(min = 48.dp),
                ) { Text(if (copied) "Copied" else "Copy the line") }
            }
        }

        Button(
            onClick = primary.second,
            modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp),
        ) { Text(primary.first) }

        OutlinedButton(
            onClick = secondary.second,
            modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp),
        ) { Text(secondary.first) }

        note?.let {
            Text(
                it,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        if (detail.isNotBlank()) {
            TextButton(
                onClick = { showDetail = !showDetail },
                modifier = Modifier.heightIn(min = 48.dp),
            ) { Text(if (showDetail) "Hide technical details" else "Show technical details") }
            if (showDetail) {
                Panel {
                    Text(
                        detail,
                        fontFamily = FontFamily.Monospace,
                        style = MaterialTheme.typography.labelSmall,
                    )
                }
            }
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
            // Two lines, not one: at the default font size "Command permission" was
            // rendered as "Command perm…" and the device line lost its Android version.
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            value,
            style = MaterialTheme.typography.bodySmall,
            maxLines = 2,
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

/**
 * A state chip that reads the same whether or not you can see colour: the label
 * carries the meaning, and "not installed" is neutral rather than an error.
 */
@Composable
internal fun StatusChip(
    online: Boolean,
    label: String? = null,
    neutral: Boolean = false,
) {
    val bg =
        when {
            neutral -> MaterialTheme.colorScheme.surfaceVariant
            online -> Tokens.SuccessContainer
            else -> MaterialTheme.colorScheme.errorContainer
        }
    val fg =
        when {
            neutral -> MaterialTheme.colorScheme.onSurfaceVariant
            online -> Tokens.OnSuccessContainer
            else -> MaterialTheme.colorScheme.onErrorContainer
        }
    Surface(color = bg, contentColor = fg, shape = RoundedCornerShape(50)) {
        Text(
            label ?: if (online) "running" else "stopped",
            style = MaterialTheme.typography.labelSmall,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
        )
    }
}

private enum class Tab(
    val label: String,
) {
    OVERVIEW("Overview"),
    PACKAGES("Packages"),
    METRICS("Metrics"),
    SETTINGS("Settings"),
}

/** "1m 20s" — a phone install is measured in minutes, so seconds alone are not enough. */
private fun elapsedText(seconds: Long): String =
    if (seconds < 60) "${seconds}s" else "${seconds / 60}m ${seconds % 60}s"

@Composable
private fun Home() {
    val context = LocalContext.current
    val result by Runner.result.collectAsState()
    val running by Runner.running.collectAsState()
    val startedAt by Runner.startedAt.collectAsState()
    val runLabel by Runner.label.collectAsState()

    var snapshot by remember { mutableStateOf<Protocol.Snapshot?>(null) }
    var actions by remember { mutableStateOf<List<Protocol.Action>>(emptyList()) }
    var failure by remember { mutableStateOf<String?>(null) }
    var askedForActions by remember { mutableStateOf(false) }
    // rememberSaveable: a rotation or a process death used to drop the user back on
    // Overview with the sub-screen closed and the scroll position lost.
    var showRawScreen by rememberSaveable { mutableStateOf(false) }
    var tabName by rememberSaveable { mutableStateOf(Tab.OVERVIEW.name) }
    var raw by remember { mutableStateOf("") }
    var steps by remember { mutableStateOf<List<Protocol.Step>>(emptyList()) }
    var pending by remember { mutableStateOf<Protocol.Action?>(null) }
    var capacity by remember { mutableStateOf<Protocol.Action?>(null) }
    var foreign by remember { mutableStateOf(Security.foreignHolders(context)) }
    var notice by remember { mutableStateOf<String?>(null) }
    var elapsed by remember { mutableStateOf(0L) }

    val tab = Tab.valueOf(tabName)
    val confirmRemove by Prefs.confirmRemove.collectAsState()
    val retainRaw by Prefs.retainRaw.collectAsState()
    val snackbar = remember { SnackbarHostState() }

    LaunchedEffect(Unit) {
        // No status request here: Root() owns the startup probe, and that probe *is* a
        // status run whose result fills this screen. Sending a second one only fought it
        // for the single transport slot.

        // Foreground supervisor: keeps a low oom_score_adj and makes Termux's death
        // visible instead of silent. It cannot prevent an LMK kill.
        runCatching { SupervisorService.start(context) }
    }

    // Tick once a second while something runs: this drives the elapsed-time readout
    // (proof that a long install is still alive) and enforces the per-caller ceiling.
    // The old screen gave a 30 s deadline to everything, including a 40-minute install.
    LaunchedEffect(running, startedAt) {
        while (running) {
            elapsed = ((System.currentTimeMillis() - startedAt) / 1000).coerceAtLeast(0)
            Runner.checkCeiling()
            delay(1000)
        }
    }

    LaunchedEffect(notice) {
        val n = notice ?: return@LaunchedEffect
        notice = null
        snackbar.showSnackbar(n)
    }

    LaunchedEffect(result) {
        val r = result ?: return@LaunchedEffect
        val fromUser = Runner.lastOrigin() == Origin.USER

        // The supervisor polls once a minute through the same transport. Its status
        // run must not overwrite the record of what the user actually just did.
        if (fromUser) {
            raw = r.stdout
            steps = Protocol.finalSteps(r.stdout)
        }

        if (r.exitCode != 0 || r.errmsg.isNotBlank()) {
            failure = Protocol.error(r.stdout, r.stderr, r.errmsg)
                ?: "Command failed (exit ${r.exitCode})"
            if (fromUser) {
                notice = if (runLabel.isBlank()) "That did not finish" else "$runLabel did not finish"
            }
            return@LaunchedEffect
        }
        failure = null
        if (fromUser) notice = if (runLabel.isBlank()) "Done" else "$runLabel — done"

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
            askedForActions = true
            Runner.send(context, listOf("--api", "list"), Origin.SYSTEM, "Read the tool list")
        }
    }

    /** Dispatch a user action and always say what happened to it. */
    fun dispatch(
        args: List<String>,
        label: String,
    ) {
        failure = null
        when (Runner.send(context, args, Origin.USER, label)) {
            Dispatch.QUEUED -> notice = "Starting $label as soon as the current run finishes."
            Dispatch.FAILED -> notice = "Could not reach Termux. Tap Refresh."
            else -> Unit
        }
    }

    // Raw output is a sub-screen of Overview, so Back must pop it — not quit the app.
    BackHandler(enabled = showRawScreen) { showRawScreen = false }

    Scaffold(
        snackbarHost = { SnackbarHost(snackbar) },
        bottomBar = {
            NavigationBar {
                Tab.values().forEach { t ->
                    NavigationBarItem(
                        selected = tab == t,
                        onClick = { tabName = t.name },
                        icon = {
                            Icon(
                                when (t) {
                                    Tab.OVERVIEW -> Icons.Filled.List
                                    Tab.PACKAGES -> PackageIcon
                                    Tab.METRICS -> MetricsIcon
                                    Tab.SETTINGS -> Icons.Filled.Settings
                                },
                                // The label below already names the tab; a description
                                // here made TalkBack say "Overview, Overview".
                                contentDescription = null,
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
                        dispatch(listOf("--api", "status"), "Read device status")
                    },
                ) { Icon(Icons.Filled.Refresh, contentDescription = "Refresh") }
            }

            if (running) {
                WorkingBanner(label = runLabel, elapsedSeconds = elapsed)
            }

            failure?.let {
                Text(
                    it,
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier =
                        Modifier
                            .padding(vertical = 4.dp)
                            .semantics { liveRegion = LiveRegionMode.Polite },
                )
            }

            when (tab) {
                Tab.OVERVIEW -> {
                    if (steps.isNotEmpty()) {
                        Section("Last run")
                        Panel {
                            steps.forEach { s ->
                                StepRow(s)
                            }
                        }
                    }

                    if (snapshot == null) {
                        // A warm launch renders this screen immediately while the probe runs,
                        // so there is a window with no Device panel at all. Say what is
                        // happening instead of leaving the page looking half-built.
                        Section("Device")
                        Panel {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
                                Text(
                                    "Reading device status…",
                                    style = MaterialTheme.typography.bodySmall,
                                    modifier = Modifier.padding(start = 8.dp),
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
                                    "Nothing is running yet. Open Packages to install a tool.",
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
                                            dispatch(
                                                listOf("--api", "run", "service.stop", "--arg", "service=${sv.name}"),
                                                "Stopping ${sv.name}",
                                            )
                                        },
                                        enabled = !running,
                                        modifier = Modifier.heightIn(min = 48.dp),
                                    ) { Text("Stop", style = MaterialTheme.typography.labelLarge) }
                                    TextButton(
                                        onClick = {
                                            dispatch(
                                                listOf(
                                                    "--api",
                                                    "run",
                                                    "service.restart",
                                                    "--arg",
                                                    "service=${sv.name}",
                                                ),
                                                "Restarting ${sv.name}",
                                            )
                                        },
                                        enabled = !running,
                                        modifier = Modifier.heightIn(min = 48.dp),
                                    ) { Text("Restart", style = MaterialTheme.typography.labelLarge) }
                                }
                            }
                            Button(
                                onClick = {
                                    dispatch(listOf("--api", "run", "service.resurrect"), "Restarting services")
                                },
                                enabled = !running,
                                modifier = Modifier.fillMaxWidth().padding(top = 4.dp).heightIn(min = 48.dp),
                            ) { Text("Restart services") }
                        }
                    }

                    Section("Security")
                    Panel {
                        if (foreign.isEmpty()) {
                            Text(
                                "Only this app can run commands in Termux.",
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
                            // The adb command is the remedy for an advanced user; it is not
                            // the message. A non-technical reader needs the plain sentence:
                            // if you did not install these, remove them.
                            Text(
                                "If you did not install one of these, uninstall it from Android " +
                                    "Settings → Apps. Technical: revoke with\n" +
                                    foreign.joinToString("\n") { Security.revokeCommand(it) },
                                fontFamily = FontFamily.Monospace,
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        TextButton(
                            onClick = { foreign = Security.foreignHolders(context) },
                            modifier = Modifier.heightIn(min = 48.dp),
                        ) { Text("Check again", style = MaterialTheme.typography.labelLarge) }
                    }

                    TextButton(
                        onClick = { showRawScreen = true },
                        modifier = Modifier.heightIn(min = 48.dp),
                    ) { Text("Show raw output") }
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
                                action.destructive -> dispatch(listOf("--api", "run", action.id, "--yes"), action.title)
                                short -> capacity = action
                                else -> dispatch(listOf("--api", "run", action.id), action.title)
                            }
                        },
                    )

                Tab.METRICS -> MetricsScreen(snapshot = snapshot)

                Tab.SETTINGS ->
                    SettingsScreen(
                        snapshot = snapshot,
                        running = running,
                        onRefresh = {
                            dispatch(listOf("--api", "status"), "Read device status")
                        },
                        onRecheckPermission = {
                            Gate.refresh(context)
                            Termux.probe(context)
                        },
                        onRunAction = { id ->
                            dispatch(listOf("--api", "run", id, "--yes"), "Removing the old pnpm project")
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
                    dispatch(listOf("--api", "run", a.id), a.title)
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
                    // The engine refuses destructive specs without this flag.
                    dispatch(listOf("--api", "run", a.id, "--yes"), a.title)
                }) { Text("Confirm") }
            },
            dismissButton = {
                TextButton(onClick = { pending = null }) { Text("Cancel") }
            },
        )
    }
}

/**
 * What is happening, and for how long.
 *
 * A background RUN_COMMAND only reports at the end, so the engine cannot stream step
 * names to the UI. Silence for forty minutes reads as "frozen", so the banner states
 * the work and the elapsed time. The long-run advice appears only after 20 s: a status
 * refresh takes eight seconds, and explaining "this can take 40 minutes" to someone
 * who is waiting eight would be its own kind of wrong.
 */
@Composable
private fun WorkingBanner(
    label: String,
    elapsedSeconds: Long,
) {
    Card(
        colors =
            CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer),
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
    ) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                Text(
                    if (label.isBlank()) "Working…" else label,
                    style = MaterialTheme.typography.titleSmall,
                    modifier = Modifier.padding(start = 8.dp).weight(1f),
                )
                Text(elapsedText(elapsedSeconds), style = MaterialTheme.typography.labelMedium)
            }
            LinearProgressIndicator(Modifier.fillMaxWidth())
            if (elapsedSeconds >= 20) {
                Text(
                    "Still working — this is normal for a large tool, which can take " +
                        "20–40 minutes on a phone. Keep this app installed; you can use " +
                        "other apps while it runs.",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

/**
 * A step's outcome, spelled out rather than spelled with a glyph.
 *
 * `✔ Collect device status` was read by TalkBack as "heavy check mark Collect device
 * status" — and a reader who cannot see the colour had no other cue for "failed".
 */
@Composable
private fun StepRow(s: Protocol.Step) {
    val word =
        when (s.state) {
            "ok" -> "Done"
            "failed" -> "Failed"
            "skipped" -> "Skipped"
            else -> "Running"
        }
    val took = if (s.ms >= 1000) "  (${s.ms / 1000}s)" else ""
    Text(
        "$word — ${s.title}$took",
        style = MaterialTheme.typography.bodySmall,
        color =
            if (s.state == "failed") {
                MaterialTheme.colorScheme.error
            } else {
                MaterialTheme.colorScheme.onSurface
            },
        modifier = Modifier.fillMaxWidth().semantics { stateDescription = word },
    )
}

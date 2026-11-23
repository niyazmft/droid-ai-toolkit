package dev.droidai.launcher

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.List
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
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
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat
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
        // Edge-to-edge: the design draws its own header rule against the status bar rather
        // than leaving a grey system strip above a page that is not grey.
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        Prefs.init(this)
        Runner.attach(this)
        Gate.refresh(this)
        setContent {
            val mode by Prefs.themeMode.collectAsState()
            val dark =
                when (mode) {
                    Prefs.THEME_LIGHT -> false
                    Prefs.THEME_DARK -> true
                    else -> isSystemInDarkTheme()
                }
            DroidTheme(darkTheme = dark) {
                // The bars are transparent now, so their icon colour is our decision, not
                // the system's: over a graphite page they must go light, over paper dark.
                SideEffect { applyBarAppearance(dark) }
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) { Root() }
            }
        }
    }

    private fun applyBarAppearance(dark: Boolean) {
        WindowCompat.getInsetsController(window, window.decorView).apply {
            isAppearanceLightStatusBars = !dark
            isAppearanceLightNavigationBars = !dark
        }
    }

    override fun onResume() {
        super.onResume()
        Gate.refresh(this)

        // Coming back from Termux, or from the system permission dialog, is the moment the
        // user has just done what we asked. Re-check automatically instead of making them
        // find a "Retry" button and press it.
        val returningFromSetup = recheckOnResume
        if (returningFromSetup && Gate.termuxInstalled.value && Gate.permissionGranted.value) {
            recheckOnResume = false
            Termux.probe(this)
            return
        }

        // Opening the app is the one moment a check costs nothing extra. Refresh only when
        // the data is actually stale and nothing else is in flight, so this cannot quietly
        // become a timer by another name.
        if (!returningFromSetup &&
            Gate.probe.value == Probe.READY &&
            !Runner.running.value &&
            System.currentTimeMillis() - Prefs.lastStatusAt.value > RESUME_REFRESH_MS
        ) {
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

        // Retry until the probe resolves.
        //
        // One send was not enough: the supervisor polls through the same single transport
        // slot, so the startup probe could be skipped entirely and the gate would sit on
        // CHECKING forever. A skipped send used to be indistinguishable from a slow one.
        LaunchedEffect(termux, permission) {
            if (!termux || !permission) return@LaunchedEffect
            while (Gate.probe.value == Probe.CHECKING) {
                if (!Runner.running.value) Termux.probe(this@MainActivity)
                delay(1500)
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
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                UiCodeBlock(it)
                TextButton(
                    onClick = {
                        clipboard.setText(AnnotatedString(it))
                        copied = true
                    },
                    modifier = Modifier.heightIn(min = 44.dp),
                ) { Text(if (copied) "Copied" else "Copy the line") }
            }
        }

        Button(
            onClick = primary.second,
            shape = androidx.compose.foundation.shape.CircleShape,
            modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp),
        ) { Text(primary.first, style = UiType.pill) }

        OutlinedButton(
            onClick = secondary.second,
            shape = androidx.compose.foundation.shape.CircleShape,
            modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp),
        ) { Text(secondary.first, style = UiType.pill) }

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
                UiCodeBlock(detail)
            }
        }
    }
}

@Composable
internal fun Section(title: String) {
    Text(
        title,
        style = UiType.subtle,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(top = 10.dp, bottom = 2.dp),
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
            modifier = Modifier.weight(0.9f),
            // Two lines, not one: at the default font size "Command permission" was
            // rendered as "Command perm…" and the device line lost its Android version.
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            value,
            // Tabular figures keep versions and sizes in a column, which is what
            // monospace used to be doing here.
            style =
                MaterialTheme.typography.bodySmall.copy(
                    fontWeight = FontWeight.Medium,
                    fontFeatureSettings = "tnum",
                ),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1.7f),
            textAlign = TextAlign.End,
        )
    }
}

/** A bordered group of related rows. */
@Composable
internal fun Panel(content: @Composable ColumnScope.() -> Unit) {
    UiCard(spacing = 6.dp, content = content)
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
    UiState(
        text = label ?: if (online) "Running" else "Stopped",
        tone =
            when {
                neutral -> StateTone.PLAIN
                online -> StateTone.OK
                else -> StateTone.ATTENTION
            },
    )
}

private enum class Tab(
    val label: String,
) {
    OVERVIEW("Overview"),
    PACKAGES("Packages"),
    METRICS("Metrics"),
    SETTINGS("Settings"),
}

/**
 * How old the visible answer is, in the shortest form that is not vague.
 *
 * It shares the header line with the model and arch — "JSN-L22 · aarch64 · 2m ago" — so it
 * has to be a couple of tokens. The old "checked 2 min ago" was an entire line of prose in
 * a place where every pixel is chrome.
 */
private fun ageShort(ageMs: Long): String =
    when {
        ageMs < 60_000L -> "just now"
        ageMs < 3_600_000L -> "${ageMs / 60_000L}m ago"
        ageMs < 86_400_000L -> "${ageMs / 3_600_000L}h ago"
        else -> "${ageMs / 86_400_000L}d ago"
    }

/**
 * The wordmark and the one always-available action.
 *
 * Fixed above the scroller rather than inside it: Refresh used to scroll away, which on a
 * phone with nothing installed meant the only control you wanted was off-screen. The
 * amber block is the identity mark — the same amber that means "this is the action"
 * everywhere else, so nothing here is decoration for its own sake.
 */
@Composable
private fun AppHeader(
    detail: String,
    age: String?,
    onRefresh: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().padding(start = 16.dp, end = 6.dp, top = 12.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text("Droid AI", style = MaterialTheme.typography.headlineSmall)
            Spacer(Modifier.height(2.dp))
            Text(
                listOfNotNull(detail, age).joinToString(" · "),
                style = UiType.meta,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        IconButton(onClick = onRefresh, modifier = Modifier.size(44.dp)) {
            Icon(
                Icons.Filled.Refresh,
                contentDescription = "Refresh",
                modifier = Modifier.size(20.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/**
 * The tab bar.
 *
 * A hand-drawn bar instead of Material's NavigationBar, because NavigationBar's identity
 * *is* the pill indicator — the one shape that made this app look like every other
 * Android app. Here the selected tab gets a 2 dp amber rule above the icon, which is how
 * a terminal marks the current tab, and the label is uppercase mono so the bar reads as a
 * row of commands rather than a row of app sections.
 */
@Composable
private fun SoftTabBar(
    current: Tab,
    onSelect: (Tab) -> Unit,
) {
    val p = Skin.palette
    val dim = MaterialTheme.colorScheme.onSurfaceVariant
    Column(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.background).navigationBarsPadding()) {
        Row(
            Modifier.fillMaxWidth().height(62.dp).padding(horizontal = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Tab.values().forEach { t ->
                val selected = t == current
                Column(
                    Modifier
                        .weight(1f)
                        .fillMaxHeight()
                        // selectable, not clickable: TalkBack needs role=Tab and the
                        // selected state, which a bare clickable does not report.
                        .selectable(selected = selected, role = Role.Tab) { onSelect(t) },
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    // The pill behind the icon is the only place the accent is used in
                    // chrome. It says "you are here" without a border under the bar.
                    Box(
                        Modifier
                            .size(width = 54.dp, height = 30.dp)
                            .background(if (selected) p.accentSoft else Color.Transparent, CircleShape),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            when (t) {
                                Tab.OVERVIEW -> Icons.Filled.List
                                Tab.PACKAGES -> PackageIcon
                                Tab.METRICS -> MetricsIcon
                                Tab.SETTINGS -> Icons.Filled.Settings
                            },
                            // The label names the tab; a description here made TalkBack
                            // say "Overview, Overview".
                            contentDescription = null,
                            modifier = Modifier.size(19.dp),
                            tint = if (selected) p.accent else dim,
                        )
                    }
                    Spacer(Modifier.height(3.dp))
                    Text(
                        t.label,
                        style = UiType.tab,
                        color = if (selected) p.accent else dim,
                    )
                }
            }
        }
    }
}

/** Don't re-read on every resume; a minute is enough to be useful without becoming a timer. */
private const val RESUME_REFRESH_MS = 60_000L

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

    // Seeded from the last saved document: with no timer, the first frame would otherwise
    // be empty. The age label below is what keeps that honest.
    var snapshot by remember { mutableStateOf(Protocol.snapshot(Prefs.lastStatus.value)) }
    var checkedAt by remember { mutableStateOf(Prefs.lastStatusAt.value) }
    var nowTick by remember { mutableStateOf(System.currentTimeMillis()) }
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
    val supervisorOn by Prefs.supervisorEnabled.collectAsState()
    val installedKnown by Prefs.installedTools.collectAsState()
    val failedTools by Prefs.failedTools.collectAsState()
    // Home is composed during a warm start while the probe is still running, so it needs
    // the gate's state too — to know when it is safe to start the supervisor.
    val probeState by Gate.probe.collectAsState()
    val snackbar = remember { SnackbarHostState() }

    // No status request here: Root() owns the startup probe, and that probe *is* a
    // status run whose result fills this screen. Sending a second one only fought it
    // for the single transport slot.
    LaunchedEffect(supervisorOn, probeState) {
        // The supervisor is what puts a permanent notification in the shade, so it is the
        // user's call (Settings → Startup & Services). Off must also remove the
        // notification, not just stop polling.
        //
        // Gated on the probe having resolved: starting it during CHECKING let its
        // `status --fast` poll win the transport slot ahead of the startup probe.
        runCatching {
            when {
                !supervisorOn -> SupervisorService.stop(context)
                probeState != Probe.CHECKING -> SupervisorService.start(context)
            }
        }
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

    // Ages are recomputed while the screen is open, so "checked 1 min ago" does not sit
    // there saying "just now" for an hour.
    LaunchedEffect(checkedAt) {
        while (true) {
            nowTick = System.currentTimeMillis()
            delay(30_000)
        }
    }

    LaunchedEffect(notice) {
        val n = notice ?: return@LaunchedEffect
        notice = null
        snackbar.showSnackbar(n)
    }

    LaunchedEffect(result) {
        val r = result ?: return@LaunchedEffect
        val origin = Runner.lastOrigin()
        val fromUser = origin == Origin.USER

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

        // Only a full snapshot may fill this screen. The supervisor polls `status --fast`,
        // which leaves version strings blank, and Packages reads "installed" from those
        // versions — accepting a fast snapshot is exactly how the app came to report
        // "0 of 8 installed" on a device with four tools installed.
        if (origin != Origin.SYSTEM) {
            Protocol.snapshot(r.stdout)?.let { snap ->
                snapshot = snap
                checkedAt = System.currentTimeMillis()
                Prefs.saveLastStatus(r.stdout)
                Prefs.setInstalledTools(
                    listOf("openclaw", "hermes", "n8n", "ollama")
                        .filter { key ->
                            when (key) {
                                "openclaw" -> snap.tools.openclaw.isNotBlank()
                                "hermes" -> snap.tools.hermes.isNotBlank()
                                "n8n" -> snap.tools.n8n.isNotBlank()
                                "ollama" -> snap.tools.ollama.isNotBlank()
                                else -> false
                            }
                        }.toSet(),
                )
            }
        }

        // Remember per-tool failure, so Packages can offer a "Needs attention" group
        // instead of leaving the user to remember which repair did not work.
        if (fromUser && Runner.lastActionId().isNotBlank()) {
            val tool = Runner.lastActionId().substringBefore('.')
            Prefs.markFailed(tool, failed = r.exitCode != 0 || r.errmsg.isNotBlank())
        }
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
        bottomBar = { SoftTabBar(tab) { tabName = it.name } },
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
        Column(Modifier.padding(pad).fillMaxSize()) {
            AppHeader(
                detail =
                    snapshot?.let { "${it.device.model} · ${it.device.arch}" }
                        ?: "Termux is ready.",
                age = if (snapshot != null && checkedAt > 0L) ageShort(nowTick - checkedAt) else null,
                onRefresh = { dispatch(listOf("--api", "status"), "Read device status") },
            )

            Column(
                Modifier
                    .weight(1f)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
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
                            // Arch lives in the header subtitle, once, next to the model.
                            // Repeating it here was noise on every screen.
                            Fact("Memory", "${s.device.memAvailableMb} MB free of ${s.device.memTotalMb} MB")
                            Fact("Swap free", "${s.device.swapFreeMb} MB")
                            Fact("Disk free", "${s.device.diskFreeMb / 1024} GB")
                            Fact("Termux", s.termux.version)
                            Fact("Boot restore", if (s.termux.bootInstalled) "installed" else "missing")
                            Fact("Node", Format.toolVersion(s.tools.node))
                            Fact("Python", Format.toolVersion(s.tools.python))
                            Fact("PM2", if (s.tools.pm2Installed) "installed" else "missing")
                            if (s.tools.openclaw.isNotBlank()) Fact("OpenClaw", Format.toolVersion(s.tools.openclaw))
                            if (s.tools.hermes.isNotBlank()) Fact("Hermes", Format.toolVersion(s.tools.hermes))
                            if (s.tools.n8n.isNotBlank()) Fact("n8n", Format.toolVersion(s.tools.n8n))
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
                                Row(horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.End)) {
                                    UiPill(
                                        label = "Stop",
                                        enabled = !running,
                                        ghost = true,
                                        onClick = {
                                            dispatch(
                                                listOf("--api", "run", "service.stop", "--arg", "service=${sv.name}"),
                                                "Stopping ${sv.name}",
                                            )
                                        },
                                    )
                                    UiPill(
                                        label = "Restart",
                                        enabled = !running,
                                        ghost = true,
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
                                    )
                                }
                            }
                            UiPill(
                                label = "Restart services",
                                enabled = !running,
                                onClick = {
                                    dispatch(listOf("--api", "run", "service.resurrect"), "Restarting services")
                                },
                            )
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
                            UiCodeBlock(foreign.joinToString("\n"))
                            // The adb command is the remedy for an advanced user; it is not
                            // the message. A non-technical reader needs the plain sentence:
                            // if you did not install these, remove them.
                            Text(
                                "If you did not install one of these, uninstall it from Android " +
                                    "Settings → Apps.",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            UiCodeBlock(foreign.joinToString("\n") { Security.revokeCommand(it) })
                        }
                        UiPill(
                            label = "Check again",
                            ghost = true,
                            onClick = { foreign = Security.foreignHolders(context) },
                        )
                    }

                    UiPill(label = "Show raw output", ghost = true, onClick = { showRawScreen = true })
                }

                Tab.PACKAGES ->
                    PackagesScreen(
                        snapshot = snapshot,
                        actions = actions,
                        running = running,
                        knownInstalled = installedKnown,
                        failedTools = failedTools,
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
    val accent = Skin.palette.accent
    Surface(
        color = MaterialTheme.colorScheme.surface,
        contentColor = MaterialTheme.colorScheme.onSurface,
        shape = MaterialTheme.shapes.medium,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
    ) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = accent)
                Text(
                    if (label.isBlank()) "Working…" else label,
                    style = MaterialTheme.typography.titleSmall,
                    modifier = Modifier.padding(start = 10.dp).weight(1f),
                )
                Text(
                    elapsedText(elapsedSeconds),
                    style = UiType.meta,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            LinearProgressIndicator(Modifier.fillMaxWidth(), color = accent)
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

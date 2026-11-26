package dev.droidai.launcher

import android.Manifest
import android.content.ComponentCallbacks2
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
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
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Info
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

class MainActivity : ComponentActivity() {
    /**
     * The screen state holder. Survives a rotation, which is what stopped the step list,
     * the raw output and the failure banner from being dropped on every config change.
     */
    private val vm: HomeViewModel by viewModels()

    /**
     * Whether the supervisor may post its notification.
     *
     * On API 33+ this is a runtime grant, and without it a foreground-service notification is
     * invisible — the supervisor would keep working and telling nobody. Held here so the
     * permission result and `onResume` both refresh the same value the screens read.
     */
    private val notificationsGranted = MutableStateFlow(false)

    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) {
            Gate.refresh(this)
            Termux.probe(this)
        }

    /**
     * Read the engine's live progress file (Task 17).
     *
     * Asked the first time a run starts, not at launch: the permission buys one thing — the
     * step line inside the running banner — and a prompt on first open would ask for it before
     * the user has any idea what it is for.
     */
    private val storageLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) {
            // Nothing to do on the result: the banner reads the file on its next tick, and an
            // unchanged elapsed-time banner is a correct fallback.
        }

    private val notificationLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) {
            // Asked once: Prefs.setNotificationAsked() ran before the dialog opened, so a
            // denial is respected and the user can still turn it on from Settings → Apps.
            refreshNotifications()
            // Re-start the supervisor so it re-posts: the first post happened while the
            // permission was missing, and an unchanged status never re-notifies by itself.
            if (notificationsGranted.value) SupervisorService.start(this)
        }

    /** Set once a probe has failed, so returning from Termux re-checks by itself. */
    private var recheckOnResume = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Edge-to-edge: the design draws its own header rule against the status bar rather
        // than leaving a grey system strip above a page that is not grey.
        enableEdgeToEdge()
        Prefs.init(this)
        Runner.attach(this)
        Gate.refresh(this)
        refreshNotifications()
        setContent {
            val mode by Prefs.themeMode.collectAsStateWithLifecycle()
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
        refreshNotifications()

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

    private fun requestNotifications() = notificationLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)

    private fun requestStorage() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            storageLauncher.launch(Manifest.permission.READ_EXTERNAL_STORAGE)
        }
    }

    private fun refreshNotifications() {
        notificationsGranted.value =
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    }

    /**
     * Android is short on memory and this process is the only thing watching Termux.
     *
     * The raw log is the one large buffer the screens keep, and it can always be re-read; the
     * process cannot be resurrected. `TRIM_MEMORY_RUNNING_LOW` is the level at which the
     * system is telling us to give something back now.
     */
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        if (level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW) vm.trimMemory()
    }

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
        val termux by Gate.termuxInstalled.collectAsStateWithLifecycle()
        val permission by Gate.permissionGranted.collectAsStateWithLifecycle()
        val probe by Gate.probe.collectAsStateWithLifecycle()
        val detail by Gate.detail.collectAsStateWithLifecycle()
        val message by Gate.message.collectAsStateWithLifecycle()
        val fix by Gate.fix.collectAsStateWithLifecycle()
        val readyBefore by Prefs.termuxReady.collectAsStateWithLifecycle()
        val notifGranted by notificationsGranted.collectAsStateWithLifecycle()

        // Home() is a sibling of the gate screens in the `when` below, so a transient
        // READY -> CHECKING -> UNREACHABLE probe makes it leave composition — and its
        // rememberSaveable state (tab, raw sub-screen, search, collapse flags) went with it.
        // That is the "the tab jumps back to Overview after unlocking the phone" report from
        // both test devices. A holder keeps the state keyed by screen, not by composition.
        val screens = rememberSaveableStateHolder()

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
                    title = stringResource(R.string.home_install_termux_first),
                    body =
                        stringResource(R.string.home_droid_ai_runs_your_ai_tools),
                    note =
                        stringResource(R.string.home_install_the_f_droid_version_not),
                    primary =
                        stringResource(R.string.home_get_termux_f_droid) to
                            { openUrl("https://f-droid.org/packages/com.termux/") },
                    secondary =
                        stringResource(R.string.home_i_already_installed_it) to { Gate.refresh(this@MainActivity) },
                )

            !permission ->
                Setup(
                    title = stringResource(R.string.home_allow_droid_ai_to_control_termux),
                    body =
                        stringResource(R.string.home_android_asks_you_to_confirm_that),
                    note = stringResource(R.string.home_nothing_is_downloaded_or_changed_until),
                    primary = stringResource(R.string.home_allow) to { requestPermission() },
                    secondary = stringResource(R.string.home_check_again) to { Gate.refresh(this@MainActivity) },
                )

            probe == Probe.CHECKING ->
                // A device that has worked before goes straight to the Overview while the
                // probe runs — the gate screens are for first-time setup, not for every
                // launch. Anything that is genuinely wrong demotes the flag in
                // Runner.classify() and the gate reappears during this same run.
                if (readyBefore) {
                    screens.SaveableStateProvider(SCREEN_HOME) {
                        Home(vm, notifGranted, ::requestNotifications, ::requestStorage)
                    }
                } else {
                    Checking()
                }

            probe == Probe.READY ->
                screens.SaveableStateProvider(SCREEN_HOME) {
                    Home(vm, notifGranted, ::requestNotifications, ::requestStorage)
                }
            probe == Probe.DENIED ->
                Setup(
                    title = stringResource(R.string.home_one_time_setup_in_termux),
                    body =
                        stringResource(R.string.home_setup_does_the_rest_itself_it),
                    code = Termux.ALLOW_EXTERNAL_APPS,
                    note =
                        stringResource(R.string.home_then_come_back_here_the_app),
                    primary =
                        stringResource(R.string.home_copy_the_line_and_open_termux) to {
                            markRecheck()
                            Termux.openTermux(this@MainActivity)
                        },
                    secondary =
                        stringResource(R.string.home_check_again) to {
                            Gate.refresh(this@MainActivity)
                            Termux.probe(this@MainActivity)
                        },
                    detail = detail,
                )

            probe == Probe.NEEDS_PACKAGES ->
                Setup(
                    title = stringResource(R.string.home_termux_is_missing_a_tool),
                    body =
                        (message.ifBlank { "Setup could not install everything it needs." }) +
                            "\n\nSetup installs the command-line tools it needs by itself. This time Termux's package manager refused, which happens when Termux's own packages are out of step with each other. One line in Termux fixes it.",
                    code = fix.ifBlank { "apt update && apt full-upgrade && apt install -y jq" },
                    note =
                        stringResource(R.string.home_after_that_come_back_here_and),
                    primary =
                        stringResource(R.string.home_copy_the_line_and_open_termux) to {
                            markRecheck()
                            Termux.openTermux(this@MainActivity)
                        },
                    secondary =
                        stringResource(R.string.home_try_again) to {
                            Gate.refresh(this@MainActivity)
                            Termux.probe(this@MainActivity)
                        },
                    detail = detail,
                )

            probe == Probe.NO_TOOLKIT ->
                Setup(
                    title = stringResource(R.string.home_setup_did_not_finish),
                    body =
                        (if (message.isNotBlank()) "$message.\n\n" else "") +
                            "Droid AI tried to download its toolkit into Termux and could not. This needs a working internet connection the first time, and a Termux whose package manager works.",
                    note = stringResource(R.string.home_check_wi_fi_or_mobile_data),
                    primary =
                        stringResource(R.string.home_try_again) to {
                            Gate.refresh(this@MainActivity)
                            Termux.probe(this@MainActivity)
                        },
                    secondary = stringResource(R.string.home_open_termux) to { Termux.openTermux(this@MainActivity) },
                    detail = detail,
                )

            probe == Probe.UNREACHABLE ->
                Setup(
                    title = stringResource(R.string.home_termux_is_not_responding),
                    body =
                        stringResource(R.string.home_android_stopped_termux_to_free_memory),
                    note = stringResource(R.string.home_open_termux_once_then_come_back),
                    primary =
                        stringResource(R.string.home_open_termux) to {
                            markRecheck()
                            Termux.openTermux(this@MainActivity)
                        },
                    secondary =
                        stringResource(R.string.home_try_again) to {
                            Gate.refresh(this@MainActivity)
                            Termux.probe(this@MainActivity)
                        },
                    detail = detail,
                )

            else ->
                Setup(
                    title = stringResource(R.string.home_termux_refused_a_command),
                    body =
                        (if (message.isNotBlank()) "$message." else "") +
                            "\n\nThe app reached Termux, but the answer was not something it understands. The details below are Termux's own words.",
                    primary =
                        stringResource(R.string.home_try_again) to {
                            Gate.refresh(this@MainActivity)
                            Termux.probe(this@MainActivity)
                        },
                    secondary = stringResource(R.string.home_open_termux) to { Termux.openTermux(this@MainActivity) },
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
            Text(stringResource(R.string.home_checking_your_device), style = MaterialTheme.typography.titleMedium)
            Text(
                stringResource(R.string.home_reading_termux_and_the_tools_you),
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
                ) {
                    Text(
                        if (copied) {
                            stringResource(
                                R.string.home_copied,
                            )
                        } else {
                            stringResource(R.string.home_copy_the_line)
                        },
                    )
                }
            }
        }

        Button(
            onClick = {
                // The label says "Copy the line and open Termux", so copy. It used to only open
                // Termux and leave the user to find the copy button.
                code?.let {
                    clipboard.setText(AnnotatedString(it))
                    copied = true
                }
                primary.second()
            },
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
            ) {
                Text(
                    if (showDetail) {
                        stringResource(
                            R.string.home_hide_technical_details,
                        )
                    } else {
                        stringResource(R.string.home_show_technical_details)
                    },
                )
            }
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

/**
 * A label and its value on one line, in two fixed columns.
 *
 * Splitting the row by *weight* (0.9 / 1.7) let the label grow with its value: at font scale
 * 1.3, "Command access" and "Termux version" each wrapped into a paragraph, which reads as
 * broken rather than as compact. The label column is now a fixed [LABEL_COLUMN] and the value
 * takes what is left, so a long label cannot push a fact onto a second line.
 *
 * A version is never ellipsised: [Fact] is for values that fit, and [FactLong] is for the ones
 * that genuinely do not. A truncated "2026.9.3" would be worse than a wrapped one.
 */
@Composable
internal fun Fact(
    label: String,
    value: String,
    /**
     * What a screen reader should say instead of [value], when the visible form is shortened.
     *
     * A version is displayed as `0.119.0` because the pre-release tail is noise on a fact row,
     * but "Termux version: 0.119.0" hides which build was tested. The full string is spoken and
     * kept in Advanced → About.
     */
    spoken: String? = null,
) {
    if (value.isBlank()) return
    Row(
        Modifier
            .fillMaxWidth()
            // One semantic node: TalkBack reads "Access: Allowed", not the two halves as
            // separate stops that mean nothing apart.
            .semantics(mergeDescendants = true) { contentDescription = "$label: ${spoken ?: value}" },
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            label,
            style = MaterialTheme.typography.bodySmall,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.width(LABEL_COLUMN),
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
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
            textAlign = TextAlign.End,
        )
    }
}

/**
 * [Fact] for a value that is genuinely too long for one line (a Hermes release string, a
 * command line). Two lines, still with the fixed label column.
 */
@Composable
internal fun FactLong(
    label: String,
    value: String,
) {
    if (value.isBlank()) return
    Row(
        Modifier
            .fillMaxWidth()
            .semantics(mergeDescendants = true) { contentDescription = "$label: $value" },
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            label,
            style = MaterialTheme.typography.bodySmall,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.width(LABEL_COLUMN),
        )
        Text(
            value,
            style =
                MaterialTheme.typography.bodySmall.copy(
                    fontWeight = FontWeight.Medium,
                    fontFeatureSettings = "tnum",
                ),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
            textAlign = TextAlign.End,
        )
    }
}

/**
 * The label column.
 *
 * 104 dp fits the longest short label used today ("Memory", "Android", "Boot restore") at
 * font scale 1.3 on a 360 dp-wide phone with the value column still ~200 dp — enough for
 * "0.119.0-beta.3" and "1794 MB". Labels that do not fit are shortened at the call site
 * ("Command access" → "Access"), never wrapped.
 */
private val LABEL_COLUMN = 104.dp

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
        text = label ?: if (online) stringResource(R.string.home_running) else stringResource(R.string.home_stopped),
        tone =
            when {
                neutral -> StateTone.PLAIN
                online -> StateTone.OK
                else -> StateTone.ATTENTION
            },
    )
}

/**
 * The two things a person does: see whether it is running, and add or update a tool.
 *
 * Settings is behind the gear in the header, not a tab, and everything technical is one tap
 * further inside it (Advanced). The old bar had four tabs whose first one was a developer
 * console — a device table with `aarch64` and `API 29`, a per-service Stop/Restart list and an
 * `adb` command — which is the wrong first screen for someone who wants their agent to work.
 */
private enum class Tab(
    val label: String,
) {
    HOME("Home"),
    TOOLS("Tools"),
}

/**
 * When the visible answer was read, as a clock time.
 *
 * It shares the header line with the model and arch — "JSN-L22 · aarch64 · 14:32" — so it
 * has to be a couple of tokens. A *relative* age ("2m ago") cannot be rendered once and
 * left alone: it needs a timer to stay honest, and that timer recomposed the whole Home
 * screen every 30 s, in the background, to change one word. A fixed time never goes stale.
 */
private fun clockShort(epochMs: Long): String =
    Instant.ofEpochMilli(epochMs).atZone(ZoneId.systemDefault()).format(CLOCK_FMT)

/** Immutable and thread-safe; a fresh `SimpleDateFormat` per call is neither cheap nor needed. */
private val CLOCK_FMT: DateTimeFormatter = DateTimeFormatter.ofPattern("HH:mm", Locale.US)

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
            Text(stringResource(R.string.home_droid_ai), style = MaterialTheme.typography.headlineSmall)
            Spacer(Modifier.height(2.dp))
            // Plain text again: the device facts open from the bar below, with Settings. Two
            // navigation doors in two different places — one in the header, one in the footer —
            // is the cognitive load this review asked us to remove.
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
                contentDescription = stringResource(R.string.home_refresh),
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
    onOpenPhone: () -> Unit,
    onSettingsClick: () -> Unit,
    onSettings: Boolean,
    onPhone: Boolean,
) {
    val p = Skin.palette
    val dim = MaterialTheme.colorScheme.onSurfaceVariant
    Column(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.background).navigationBarsPadding()) {
        Row(
            // heightIn, not a fixed height: a fixed 62 dp cannot grow, so at a large font scale
            // the label had nowhere to go. The children below use `weight`, not `fillMaxHeight`,
            // for the same reason — a Scaffold bottomBar is measured with an unbounded max
            // height, and `fillMaxHeight` against an infinite constraint collapses the whole
            // Scaffold (the content went blank and the bar floated mid-screen when tried).
            Modifier.fillMaxWidth().heightIn(min = 62.dp).padding(horizontal = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Tab.values().forEach { t ->
                // selectable, not clickable: TalkBack needs role=Tab and the selected state,
                // which a bare clickable does not report. weight lives inside BarItem.
                TabItem(
                    tab = t,
                    selected = t == current && !onSettings && !onPhone,
                    onSelect = onSelect,
                )
            }

            // Both "go somewhere else" doors live here, next to one another, in the bar the
            // thumb is already at. They used to be split: Settings in the header, the device
            // facts behind the phone name *also* in the header — two navigation targets above
            // the content and none below, which is the opposite of where a phone user looks.
            //
            // All four get the same width and the same shape (icon over label), so the bar has
            // one rhythm: two of them happen to mark a tab you are on and two do not. Clustering
            // the doors at the right edge instead left an empty gutter in the middle and made
            // the bar read as two bars.
            BarItem(
                icon = Icons.Filled.Info,
                label = stringResource(R.string.home_device),
                description = stringResource(R.string.home_about_phone),
                selected = onPhone,
                tint = dim,
                onClick = onOpenPhone,
            )
            BarItem(
                icon = Icons.Filled.Settings,
                label = stringResource(R.string.home_settings),
                description = stringResource(R.string.home_settings),
                selected = onSettings,
                tint = dim,
                onClick = onSettingsClick,
            )
        }
    }
}

/**
 * A tab: the same look as a door, with the semantics of a tab.
 *
 * `selectable` cannot be folded into [BarItem] without giving the doors a role they do not have,
 * so the tab wraps the shared shape in its own selector.
 */
@Composable
private fun RowScope.TabItem(
    tab: Tab,
    selected: Boolean,
    onSelect: (Tab) -> Unit,
) {
    val p = Skin.palette
    Column(
        Modifier
            .weight(1f)
            // weight, not fillMaxHeight: the bar is measured with an unbounded max height (it is
            // a Scaffold bottomBar), and fillMaxHeight against an infinite constraint collapses
            // the whole Scaffold — the content went blank and the bar floated mid-screen when
            // this was tried.
            .fillMaxWidth()
            .selectable(selected = selected, role = Role.Tab) { onSelect(tab) }
            .padding(vertical = 6.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        // The pill behind the icon is the only place the accent is used in chrome. It says
        // "you are here" without a border under the bar.
        Box(
            Modifier
                .size(width = 54.dp, height = 30.dp)
                .background(if (selected) p.accentSoft else Color.Transparent, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                when (tab) {
                    Tab.HOME -> Icons.Filled.Home
                    Tab.TOOLS -> PackageIcon
                },
                // The label names the tab; a description here made TalkBack say
                // "Overview, Overview".
                contentDescription = null,
                modifier = Modifier.size(19.dp),
                tint = if (selected) p.accent else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Spacer(Modifier.height(3.dp))
        Text(
            tab.label,
            style = UiType.tab,
            color = if (selected) p.accent else MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
        )
    }
}

/**
 * One segment of the bottom bar: an icon in a pill, a label under it, equal width.
 *
 * Shared by the two tabs and the two doors on purpose — the bar has one rhythm, and a door that
 * is drawn differently from its neighbours reads as a different kind of thing. The pill only
 * appears for the segment you are *on*; a door has no "here" state, so it never shows one.
 */
@Composable
private fun RowScope.BarItem(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    description: String,
    selected: Boolean,
    tint: Color,
    onClick: () -> Unit,
) {
    val p = Skin.palette
    Column(
        Modifier
            .weight(1f)
            .fillMaxWidth()
            .clickable(role = Role.Button, onClick = onClick)
            .semantics(mergeDescendants = true) { contentDescription = description }
            .padding(vertical = 6.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Box(
            Modifier
                .size(width = 54.dp, height = 30.dp)
                .background(if (selected) p.accentSoft else Color.Transparent, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                icon,
                // The label under it names the segment; a description here makes TalkBack say
                // the name twice.
                contentDescription = null,
                modifier = Modifier.size(19.dp),
                tint = if (selected) p.accent else tint,
            )
        }
        Spacer(Modifier.height(3.dp))
        Text(
            label,
            style = UiType.tab,
            color = if (selected) p.accent else tint,
            maxLines = 1,
        )
    }
}

/** Don't re-read on every resume; a minute is enough to be useful without becoming a timer. */
private const val RESUME_REFRESH_MS = 60_000L

/** Log tags are cheap; a swallowed exception with no trace is what cost us the API 34 bug. */
private const val TAG = "DroidAI"

/** Key for the screens' saved state; one screen owns it today, and the name says which. */
private const val SCREEN_HOME = "home"

/**
 * "1m 20s" — a phone install is measured in minutes, so seconds alone are not enough.
 *
 * Kept as arithmetic rather than a string resource: it is two numbers and a unit, and a
 * translated format would need arguments at every call site (this is called from a plain
 * function, not from a composable).
 */
private fun elapsedText(seconds: Long): String =
    if (seconds < 60) "${seconds}s" else "${seconds / 60}m ${seconds % 60}s"

@Composable
private fun Home(
    vm: HomeViewModel,
    notificationsGranted: Boolean,
    onRequestNotifications: () -> Unit,
    onRequestStorage: () -> Unit,
) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val s by vm.state.collectAsStateWithLifecycle()
    val retainRaw by Prefs.retainRaw.collectAsStateWithLifecycle()
    val supervisorOn by Prefs.supervisorEnabled.collectAsStateWithLifecycle()
    val installedKnown by Prefs.installedTools.collectAsStateWithLifecycle()
    val failedTools by Prefs.failedTools.collectAsStateWithLifecycle()
    val notificationAsked by Prefs.notificationAsked.collectAsStateWithLifecycle()
    // Home is composed during a warm start while the probe is still running, so it needs
    // the gate's state too — to know when it is safe to start the supervisor.
    val probeState by Gate.probe.collectAsStateWithLifecycle()
    val accessAllowed by Gate.permissionGranted.collectAsStateWithLifecycle()

    // rememberSaveable: a rotation or a process death used to drop the user back on
    // Overview with the sub-screen closed and the scroll position lost.
    var showRawScreen by rememberSaveable { mutableStateOf(false) }
    var showSettings by rememberSaveable { mutableStateOf(false) }
    var showPhone by rememberSaveable { mutableStateOf(false) }
    var tabName by rememberSaveable { mutableStateOf(Tab.HOME.name) }
    var showFailureDetails by rememberSaveable { mutableStateOf(false) }
    val snackbar = remember { SnackbarHostState() }
    // A link out of the app (Termux:Boot on F-Droid). `openUrl` is MainActivity's, and this
    // composable is not inside it, so the same three lines live here.
    val openExternal: (String) -> Unit = { url ->
        runCatching {
            context.startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }
    val tab = Tab.valueOf(tabName)

    // The supervisor is what puts a permanent notification in the shade, so it is the user's
    // call (Settings → Startup & Services). Off must also remove the notification, not just
    // stop polling.
    //
    // Bound to STARTED, not to composition: a Composition outlives STOP, and starting a
    // foreground service while the app is in the background is not allowed (and used to be
    // swallowed by a bare runCatching). Gated on the probe having resolved, because starting
    // it during CHECKING let its `status --fast` poll win the transport slot ahead of the
    // startup probe.
    LaunchedEffect(supervisorOn, probeState, lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            try {
                when {
                    !supervisorOn -> SupervisorService.stop(context)
                    probeState != Probe.CHECKING -> SupervisorService.start(context)
                }
            } catch (e: Exception) {
                // ForegroundServiceStartNotAllowedException, chiefly. Say so instead of
                // pretending the notification is being maintained.
                Log.w(TAG, "could not start the status service", e)
                vm.say("Android would not start the status service. Try again with the app open.")
            }
        }
    }

    // Live progress needs one read permission; ask when there is finally something to show,
    // and only once per process (a denied prompt must not come back on every install).
    var storageAsked by remember { mutableStateOf(false) }
    LaunchedEffect(s.running) {
        if (s.running && !storageAsked && !Progress.canRead(context)) {
            storageAsked = true
            onRequestStorage()
        }
    }

    // On API 33+ the supervisor's notification is invisible without this grant, which
    // silently defeats the only thing it exists for. Asked in context, once.
    LaunchedEffect(supervisorOn, notificationsGranted, notificationAsked) {
        if (supervisorOn && !notificationsGranted && Build.VERSION.SDK_INT >= 33 && !notificationAsked) {
            Prefs.setNotificationAsked()
            onRequestNotifications()
        }
    }

    // One-shot messages: a completion must be shown once, not re-shown after a rotation.
    LaunchedEffect(lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            vm.notices.collect { snackbar.showSnackbar(it) }
        }
    }

    // Opening Packages is an explicit ask for the tool list: allow one more attempt if the
    // first one was lost to a busy transport (see HomeViewModel.onCatalogScreenOpened).
    //
    // It is also the one screen that shows tool versions, so it is where the slow, full read
    // belongs — app launch and resume only need `--fast` (HomeViewModel.onToolsScreenOpened).
    LaunchedEffect(tab) {
        if (tab == Tab.TOOLS) {
            vm.onCatalogScreenOpened()
            vm.onToolsScreenOpened()
        }
    }

    // Sub-screens are pushed, not tab-switched: Settings is behind the gear (and raw output
    // behind Settings → Diagnostics), the device facts behind the phone name in the header.
    // Back must pop one level, never quit the app.
    BackHandler(enabled = showRawScreen) { showRawScreen = false }
    BackHandler(enabled = !showRawScreen && showPhone) { showPhone = false }
    BackHandler(enabled = !showRawScreen && !showPhone && showSettings) { showSettings = false }

    Scaffold(
        snackbarHost = { SnackbarHost(snackbar) },
        // A sub-screen is a full-page detour, so it has no tab bar: offering one would only
        // invite leaving the page you just opened.
        // The bar is on every screen, always. It used to disappear on Settings, the device facts
        // and the raw output — so the one place a thumb goes to move between screens vanished
        // exactly on the screens that are not the tabs, and Back was the only way out.
        bottomBar = {
            SoftTabBar(
                current = tab,
                // A sub-screen owns the highlight: Raw Output is reached from Settings, so it
                // belongs to Settings rather than to the tab underneath.
                onSettings = showSettings || showRawScreen,
                onPhone = showPhone,
                onSelect = {
                    tabName = it.name
                    showSettings = false
                    showPhone = false
                    showRawScreen = false
                },
                onOpenPhone = {
                    showSettings = false
                    showRawScreen = false
                    showPhone = true
                },
                onSettingsClick = {
                    showPhone = false
                    showRawScreen = false
                    showSettings = true
                },
            )
        },
    ) { pad ->
        when {
            showRawScreen -> {
                Box(Modifier.padding(pad)) {
                    RawOutputScreen(
                        raw = if (retainRaw) s.raw else "",
                        retained = retainRaw,
                        onBack = { showRawScreen = false },
                    )
                }
                return@Scaffold
            }

            showPhone -> {
                Column(Modifier.padding(pad).fillMaxSize()) {
                    PinnedBanners(
                        state = s,
                        onDetails = { showFailureDetails = true },
                        onDismiss = { vm.dismissFailure() },
                    )
                    SubScreenHeader(
                        title = stringResource(R.string.phone_about_this_phone),
                        onBack = { showPhone = false },
                    )
                    Box(Modifier.weight(1f)) {
                        PhoneScreen(snapshot = s.snapshot)
                    }
                }
                return@Scaffold
            }

            showSettings -> {
                // SettingsScreen has no scroller of its own (the tab content used to own it), so
                // the page must provide one — without this the lower sections were clipped and
                // unreachable, which is how Advanced became untappable on the first build.
                Column(Modifier.padding(pad).fillMaxSize()) {
                    PinnedBanners(
                        state = s,
                        onDetails = { showFailureDetails = true },
                        onDismiss = { vm.dismissFailure() },
                    )
                    SubScreenHeader(
                        title = stringResource(R.string.settings_settings),
                        onBack = { showSettings = false },
                    )
                    Box(Modifier.weight(1f)) {
                        Column(Modifier.verticalScroll(rememberScrollState())) {
                            SettingsScreen(
                                snapshot = s.snapshot,
                                running = s.running,
                                notificationsGranted = notificationsGranted,
                                foreign = s.foreign,
                                onRefresh = { vm.refresh() },
                                onRecheckPermission = {
                                    Gate.refresh(context)
                                    Termux.probe(context)
                                },
                                onRequestNotifications = onRequestNotifications,
                                onRunAction = { id ->
                                    val label =
                                        if (id == "service.boot") {
                                            "Setting up after reboot"
                                        } else {
                                            "Removing the old pnpm project"
                                        }
                                    vm.runConfirmed(id, label)
                                },
                                onCheckAgain = {
                                    vm.refreshForeign()
                                    Gate.refresh(context)
                                    Termux.probe(context)
                                },
                                // Raw output used to be Settings → Advanced → Diagnostics. The
                                // middle screen is gone, so the terminal output lives one tap
                                // from the setting that talks about it.
                                onOpenRawOutput = { showRawScreen = true },
                                onBack = { showSettings = false },
                                onTestBoot = { vm.testBoot() },
                                onOpenBootApp = { openExternal("https://f-droid.org/packages/com.termux.boot/") },
                            )
                        }
                    }
                }
                return@Scaffold
            }
        }

        Column(Modifier.padding(pad).fillMaxSize()) {
            AppHeader(
                detail =
                    s.snapshot?.let {
                        // Model only. The arch used to sit here too, which is a word a
                        // non-technical reader cannot use; it lives in Advanced now.
                        it.device.model
                    } ?: "Termux is ready.",
                age = if (s.snapshot != null && s.checkedAt > 0L) clockShort(s.checkedAt) else null,
                onRefresh = { vm.refresh() },
            )

            PinnedBanners(state = s, onDetails = { showFailureDetails = true }, onDismiss = { vm.dismissFailure() })

            Column(
                Modifier
                    .weight(1f)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                when (tab) {
                    Tab.HOME ->
                        HomeBody(
                            snapshot = s.snapshot,
                            services = s.snapshot?.services.orEmpty(),
                            steps = s.steps,
                            installedKnown = installedKnown,
                            actions = s.actions,
                            running = s.running,
                            failedTools = failedTools,
                            onChooseTool = { tabName = Tab.TOOLS.name },
                            onRestartEverything = { vm.runService("service.resurrect", null, "Restarting services") },
                            onRun = { action -> vm.onRun(action) },
                        )

                    Tab.TOOLS ->
                        PackagesScreen(
                            snapshot = s.snapshot,
                            actions = s.actions,
                            running = s.running,
                            knownInstalled = installedKnown,
                            failedTools = failedTools,
                            onRun = { action -> vm.onRun(action) },
                        )
                }
            }
        }
    }

    s.failure?.takeIf { showFailureDetails && it.details.isNotEmpty() }?.let { f ->
        AlertDialog(
            onDismissRequest = { showFailureDetails = false },
            title = { Text(f.headline) },
            text = {
                Column(
                    Modifier.verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    f.details.forEach { line ->
                        Text(
                            line,
                            style = MaterialTheme.typography.bodySmall,
                            // Monospace: these are command lines and paths, and the
                            // alignment carries information (the apt "E:" prefix, the
                            // pnpm progress columns).
                            fontFamily = FontFamily.Monospace,
                        )
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { showFailureDetails = false }) { Text(stringResource(R.string.home_close)) }
            },
            // The dialog replays the last 12 lines of the failing step; the rest of the stream
            // is in Advanced → Diagnostics. Sending the reader there from the evidence is the
            // difference between "here is why" and "here is why, and here is everything".
            dismissButton = {
                TextButton(onClick = {
                    showFailureDetails = false
                    showRawScreen = true
                }) { Text(stringResource(R.string.home_open_full_output)) }
            },
        )
    }

    s.capacity?.let { a ->
        AlertDialog(
            onDismissRequest = { vm.cancelCapacity() },
            title = { Text(stringResource(R.string.home_this_device_may_not_fit, a.title)) },
            text = {
                Text(
                    (
                        if (a.minMemMb > 0) {
                            "${a.title} asks for ${a.minMemMb} MB free memory; this device has ${s.snapshot?.device?.memAvailableMb ?: 0} MB.\n\n"
                        } else {
                            ""
                        }
                    ) +
                        (
                            if (a.minDiskMb > 0) {
                                "It asks for ${a.minDiskMb} MB free storage; this device has ${s.snapshot?.device?.diskFreeMb ?: 0} MB.\n\n"
                            } else {
                                ""
                            }
                        ) +
                        "Installing anyway usually ends with Android killing it part-way. Close something and tap Refresh first, or continue at your own risk.",
                )
            },
            confirmButton = {
                TextButton(onClick = { vm.confirmCapacity() }) { Text(stringResource(R.string.home_install_anyway)) }
            },
            dismissButton = {
                TextButton(onClick = { vm.cancelCapacity() }) { Text(stringResource(R.string.home_cancel)) }
            },
        )
    }

    s.pending?.let { a ->
        AlertDialog(
            onDismissRequest = { vm.cancelPending() },
            title = { Text(a.title) },
            text = { Text(a.summary + "\n\nThis cannot be undone.") },
            confirmButton = {
                TextButton(onClick = { vm.confirmPending() }) { Text(stringResource(R.string.home_confirm)) }
            },
            dismissButton = {
                TextButton(onClick = { vm.cancelPending() }) { Text(stringResource(R.string.home_cancel)) }
            },
        )
    }
}

/**
 * The running banner and the failure banner, pinned above whatever screen is open.
 *
 * Both used to live inside the Home tab's column, so an install started from Advanced hid the
 * "Working…" line — the only sign the tap did anything — and a failure raised there stayed
 * invisible until the user navigated back.
 */
@Composable
private fun PinnedBanners(
    state: HomeState,
    onDetails: () -> Unit,
    onDismiss: () -> Unit,
) {
    if (state.running) {
        Box(Modifier.padding(horizontal = 16.dp)) {
            WorkingBanner(
                label = state.runLabel,
                elapsedSeconds = state.elapsedSeconds,
                step = state.progress,
            )
        }
    }

    state.failure?.let { f ->
        Box(Modifier.padding(horizontal = 16.dp)) {
            Row(
                Modifier.fillMaxWidth().padding(vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    f.headline,
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier =
                        Modifier
                            .weight(1f)
                            .semantics { liveRegion = LiveRegionMode.Polite },
                )
                if (f.details.isNotEmpty()) {
                    Text(
                        stringResource(R.string.home_details),
                        color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.labelLarge,
                        modifier =
                            Modifier
                                .clickable(onClickLabel = stringResource(R.string.home_show_what_failed)) {
                                    onDetails()
                                }.padding(vertical = 4.dp, horizontal = 4.dp),
                    )
                }
                Text(
                    stringResource(R.string.home_dismiss),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.labelLarge,
                    modifier =
                        Modifier
                            .clickable(onClickLabel = stringResource(R.string.home_dismiss_the_failure)) {
                                onDismiss()
                            }.padding(vertical = 4.dp, horizontal = 4.dp),
                )
            }
        }
    }
}

/**
 * Home: one sentence of state and one button.
 *
 * Everything the old Overview put here — the eleven-row device table, per-service Stop/Restart,
 * the Security panel, raw output — is in Advanced (Settings → Advanced). What is left is what a
 * person can act on before knowing what `aarch64` means: whether it is running, and what to do
 * next.
 *
 * "Last run" stays because it is the only confirmation that an install or restart finished, and
 * a completion message that scrolled away is not a record.
 */
@Composable
private fun HomeBody(
    snapshot: Protocol.Snapshot?,
    services: List<Protocol.Service>,
    steps: List<Protocol.Step>,
    installedKnown: Set<String>,
    actions: List<Protocol.Action>,
    running: Boolean,
    failedTools: Set<String>,
    onChooseTool: () -> Unit,
    onRestartEverything: () -> Unit,
    onRun: (Protocol.Action) -> Unit,
) {
    val servicesUp = snapshot?.services?.count { it.status == "online" } ?: 0
    val installed =
        maxOf(
            snapshot?.installedKeys()?.size ?: 0,
            installedKnown.size,
        )
    val verdict =
        HomeSummary.verdict(
            installed = installed,
            running = servicesUp,
            needsAttention = failedTools.isNotEmpty(),
        )
    val action = HomeSummary.action(verdict)

    Text(
        HomeSummary.headline(verdict, servicesUp),
        style = MaterialTheme.typography.headlineSmall,
    )
    Text(
        HomeSummary.detail(verdict),
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )

    action?.let {
        Button(
            onClick = {
                when (it) {
                    HomeSummary.Action.CHOOSE_TOOL -> onChooseTool()
                    HomeSummary.Action.RESTART_EVERYTHING -> onRestartEverything()
                }
            },
            shape = CircleShape,
            enabled = !running,
            modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(top = 8.dp),
        ) { Text(HomeSummary.actionLabel(it), style = UiType.pill) }
    }

    // F28: on a device with nothing installed, one recommended tool with a one-line "what
    // this gives you". A wall of eight cards is a decision; one card is a next step. It is
    // deliberately absent once anything is installed — the Tools tab is the list.
    if (verdict == HomeSummary.Verdict.NOTHING_INSTALLED) {
        val recommended =
            actions.firstOrNull { it.id == RECOMMENDED_TOOL } ?: actions.firstOrNull { !it.destructive }
        recommended?.let { action ->
            Section(stringResource(R.string.home_recommended))
            Panel {
                Text(action.title, style = MaterialTheme.typography.titleMedium)
                Text(
                    action.summary.ifBlank { "The one most people start with." },
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                UiPill(
                    label = stringResource(R.string.home_install),
                    enabled = !running,
                    onClick = { onRun(action) },
                )
            }
        }
    }

    // Home used to end here, on every device with everything running: a headline, a sentence
    // and empty space. "1 tool running" is a verdict, not information — a reader could not tell
    // *which* tool, or how much of the phone it was using, without going to another screen.
    // These two panels are painted from the snapshot the app already holds, so they are as
    // fresh as the last read and cost nothing extra: they simply do not update every second,
    // which was never the point.
    if (services.isNotEmpty()) {
        Section(stringResource(R.string.home_running_now))
        Panel {
            services.forEach { sv ->
                RunningRow(sv)
            }
            UiPill(
                label = HomeSummary.actionLabel(HomeSummary.Action.RESTART_EVERYTHING),
                enabled = !running,
                ghost = true,
                onClick = onRestartEverything,
            )
        }
    } else if (verdict != HomeSummary.Verdict.NOTHING_INSTALLED) {
        Section(stringResource(R.string.home_running_now))
        Panel {
            Text(
                stringResource(R.string.home_nothing_running_yet),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }

    val installedTools = snapshot?.tools
    if (installedTools != null && installed > 0) {
        Section(stringResource(R.string.home_installed))
        Panel {
            ToolLine("OpenClaw", installedTools.openclaw, services, running = "openclaw")
            ToolLine("Hermes", installedTools.hermes, services, running = "hermes")
            ToolLine("n8n", installedTools.n8n, services, running = "n8n")
        }
    }

    // The last run's steps are gone from Home: a finished run's step list is a receipt, and
    // reading it here competed with what is happening *now*. The failure banner still replays
    // the failing step's own output, and the whole stream is in Settings → Diagnostics.
    if (steps.isNotEmpty() && running) {
        Section(stringResource(R.string.home_last_run))
        Panel {
            steps.forEach { step -> StepRow(step) }
        }
    }
}

/**
 * One running service: name, what it is costing, and whether it is actually up.
 *
 * The memory figure is the reason this row exists — "running" can mean 40 MB or 600 MB, and on
 * a phone that kills background apps the second number is the one that explains tomorrow.
 */
@Composable
private fun RunningRow(sv: Protocol.Service) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(sv.name, style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
        Text(
            stringResource(R.string.home_mb_restarts, sv.memMb, sv.restarts),
            style = UiType.meta,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.width(8.dp))
        StatusChip(sv.status == "online")
    }
}

/**
 * One installed tool on Home: what version, and whether it is among the running services.
 *
 * `version` is blank when the tool did not answer or the last read was `--fast`; the row then
 * says only what it knows rather than inventing a version or claiming the tool is missing.
 */
@Composable
private fun ToolLine(
    name: String,
    version: String,
    services: List<Protocol.Service>,
    running: String,
) {
    val short = Format.toolVersion(version)
    val up = services.any { it.name == running && it.status == "online" }
    if (short.isBlank() && version.isBlank() && !up) return
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(name, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
        if (short.isNotBlank()) {
            Text(
                short,
                style = UiType.meta,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.width(8.dp))
        }
        UiState(
            text = stringResource(if (up) R.string.home_running else R.string.home_stopped),
            tone = if (up) StateTone.OK else StateTone.PLAIN,
        )
    }
}

/**
 * The one tool offered on an empty device.
 *
 * OpenClaw because it is what this toolkit is built around: a gateway that answers in a chat
 * app, which is the shortest path from "I installed this app" to "something works".
 */
private const val RECOMMENDED_TOOL = "openclaw.install"

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
    step: Progress.Step? = null,
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
            // The live step, when the engine can publish one (Task 17). Absent is normal: it
            // needs shared storage, and the elapsed time above already answers "is it alive".
            if (step != null) {
                Text(
                    Progress.label(step),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurface,
                )
            }
            if (elapsedSeconds >= 20) {
                Text(
                    stringResource(R.string.home_still_working_this_is_normal_for),
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
        stringResource(R.string.home_text, word, s.title, took),
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

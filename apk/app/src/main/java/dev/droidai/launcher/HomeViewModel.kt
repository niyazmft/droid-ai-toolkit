package dev.droidai.launcher

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Everything a run produces, as one immutable value.
 *
 * This used to live in a dozen `remember` slots inside `Home()`, which meant a rotation
 * silently dropped the step list, the raw output and the pinned failure banner — and, worse,
 * re-ran `LaunchedEffect(result)` on the *stale* result, queueing a second status run and
 * re-showing a completion message for work that had happened before the rotate. A ViewModel
 * is the platform's answer to exactly that, and it survives configuration change by design
 * (D13).
 *
 * What deliberately stays in the composable: which tab is open, whether the raw sub-screen
 * is showing, the search query, collapse state, dialog visibility, and the "now" used to age
 * the last check. Those are view position, not application state.
 */
data class HomeState(
    /** The last full status document, parsed. `null` until one exists. */
    val snapshot: Protocol.Snapshot? = null,
    val checkedAt: Long = 0L,
    /**
     * When the last *full* read completed (0 = never, in this process).
     *
     * Separate from [checkedAt] because a `--fast` read refreshes that one on every unlock with
     * blank versions. This is what decides whether opening Tools has to spend the slow read.
     */
    val lastFullAt: Long = 0L,
    val actions: List<Protocol.Action> = emptyList(),
    /** Final state of each step in the last run the *user* started. */
    val steps: List<Protocol.Step> = emptyList(),
    val raw: String = "",
    /** The pinned failure banner, with the evidence behind it. */
    val failure: Protocol.Failure? = null,
    val running: Boolean = false,
    val runLabel: String = "",
    val elapsedSeconds: Long = 0L,
    /**
     * The step the engine says it is on, when shared storage makes that readable.
     *
     * Null is the normal case: it needs `termux-setup-storage` in Termux, and the banner then
     * shows the elapsed time instead (which is what it did before this existed).
     */
    val progress: Progress.Step? = null,
    /** A destructive action awaiting confirmation. */
    val pending: Protocol.Action? = null,
    /** An action whose `min_mem_mb`/`min_disk_mb` this device does not meet. */
    val capacity: Protocol.Action? = null,
    /** Packages other than this app that can run commands in Termux. */
    val foreign: List<String> = emptyList(),
)

/**
 * The state machine behind the Overview and Packages screens.
 *
 * ## Why results are collected here, once
 *
 * `Runner.completions` is a buffered `SharedFlow`, collected in `viewModelScope`: sequential,
 * never cancelled half-way by a recomposition, and never conflated (D15). The previous shape
 * — `collectAsState()` plus `LaunchedEffect(result)` — had all three failure modes at once.
 *
 * ## Why the clock lives here
 *
 * The elapsed-time readout is a property of the run, not of the screen, so it ticks while a
 * run is in flight even if the user switches tabs. It also calls [Runner.checkCeiling] every
 * second: that is the safety net that clears a run whose result never arrived, and it must
 * not depend on anything being on screen.
 */
class HomeViewModel(
    application: Application,
    private val saved: SavedStateHandle,
) : AndroidViewModel(application) {
    private val app = application
    private val _state = MutableStateFlow(HomeState())
    val state: StateFlow<HomeState> = _state.asStateFlow()

    /**
     * One-shot messages for the snackbar.
     *
     * A `Channel`, not a value in [state]: a completion message must be shown once, not
     * re-shown every time the screen is recreated.
     */
    private val _notices = Channel<String>(Channel.BUFFERED)
    val notices: Flow<String> = _notices.receiveAsFlow()

    /** At most one `--api list` per process, so a device with no catalog does not loop. */
    private var catalogRequested = false

    private var clock: Job? = null

    init {
        restoreAfterProcessDeath()

        // The previous answer, so the first frame is not empty. Read on IO (it is a file), and
        // parsed off the main thread (it is NDJSON).
        viewModelScope.launch {
            val saved = StatusStore.load(app)
            if (saved.isNotBlank()) {
                val parsed = withContext(Dispatchers.Default) { Protocol.parse(saved) }
                parsed.snapshot?.let { snap ->
                    _state.update { it.copy(snapshot = snap, checkedAt = Prefs.lastStatusAt.value) }
                }
            }
            maybeRequestCatalog()
        }

        // A PackageManager query is a Binder call; not on the main thread for a first frame.
        viewModelScope.launch(Dispatchers.IO) {
            _state.update { it.copy(foreign = Security.foreignHolders(app)) }
        }

        viewModelScope.launch { Runner.completions.collect { handle(it) } }

        viewModelScope.launch {
            Runner.running.collect { running ->
                _state.update { it.copy(running = running) }
                if (running) startClock() else stopClock()
                // No catalog request here on purpose: this block can resume inside the
                // transport's critical section (a StateFlow write runs a Main.immediate
                // collector inline), and the catalogue decision needs the parsed result,
                // which [handle] has and this does not.
            }
        }

        viewModelScope.launch {
            Runner.label.collect { label -> _state.update { it.copy(runLabel = label) } }
        }
    }

    // ---- callers -------------------------------------------------------------------------

    /** A full, non-`--fast` read: this is what fills versions in Packages. */
    fun refresh() = dispatch(listOf("--api", "status"), "Read device status")

    /**
     * Run a catalog action, after the two dialogs the catalog can demand.
     *
     * The order matters and is the engine's: a destructive action asks for confirmation, a
     * device that does not meet the declared budget asks before starting, and everything
     * else goes straight through.
     */
    fun onRun(action: Protocol.Action) {
        val snap = _state.value.snapshot
        val short =
            snap != null &&
                (
                    (action.minMemMb > 0 && snap.device.memAvailableMb < action.minMemMb) ||
                        (action.minDiskMb > 0 && snap.device.diskFreeMb < action.minDiskMb)
                )

        when {
            action.destructive && Prefs.confirmRemove.value -> _state.update { it.copy(pending = action) }
            action.destructive -> dispatch(listOf("--api", "run", action.id, "--yes"), action.title)
            short -> _state.update { it.copy(capacity = action) }
            else -> dispatch(listOf("--api", "run", action.id), action.title)
        }
    }

    fun confirmPending() {
        val action = _state.value.pending ?: return
        _state.update { it.copy(pending = null) }
        // The engine refuses a destructive spec without this flag.
        dispatch(listOf("--api", "run", action.id, "--yes"), action.title)
    }

    fun cancelPending() = _state.update { it.copy(pending = null) }

    fun confirmCapacity() {
        val action = _state.value.capacity ?: return
        _state.update { it.copy(capacity = null) }
        // `--force` overrides capacity only; arch and predicates stay hard in the engine.
        dispatch(listOf("--api", "run", action.id, "--force"), action.title)
    }

    fun cancelCapacity() = _state.update { it.copy(capacity = null) }

    fun dismissFailure() {
        _state.update { it.copy(failure = null) }
        persistFailure(null)
    }

    /**
     * A service row action (`service.stop`, `service.restart`, `service.resurrect`).
     *
     * The target travels as `--arg service=<name>`, which is the engine's argument
     * primitive — the app never interpolates a name into a shell string.
     */
    fun runService(
        actionId: String,
        service: String?,
        label: String,
    ) {
        val args =
            buildList {
                add("--api")
                add("run")
                add(actionId)
                if (service != null) {
                    add("--arg")
                    add("service=$service")
                }
            }
        dispatch(args, label)
    }

    /** Run an action a screen has already confirmed (Settings → legacy-folder cleanup). */
    fun runConfirmed(
        id: String,
        label: String,
    ) = dispatch(listOf("--api", "run", id, "--yes"), label)

    fun refreshForeign() {
        viewModelScope.launch(Dispatchers.IO) {
            _state.update { it.copy(foreign = Security.foreignHolders(app)) }
        }
    }

    /** Say something in the app's voice, once. */
    fun say(message: String) {
        _notices.trySend(message)
    }

    /**
     * Android is short on memory: drop what can be re-read.
     *
     * The raw buffer is the only large thing this screen holds, and it is a debugging aid —
     * losing it is always better than losing the process that is watching Termux.
     */
    fun trimMemory() {
        _state.update { it.copy(raw = "") }
    }

    override fun onCleared() {
        stopClock()
        super.onCleared()
    }

    // ---- internals -----------------------------------------------------------------------

    private fun dispatch(
        args: List<String>,
        label: String,
    ) {
        // Starting an action is a retry, so the previous verdict goes. Re-reading the device
        // is not: Refresh is a USER run too, and tapping it to ask "is it fixed now?" must not
        // delete the sentence that says what was broken.
        if (args.getOrNull(1) == "run") {
            _state.update { it.copy(failure = null) }
            persistFailure(null)
        }
        when (Runner.send(app, args, Origin.USER, label)) {
            Dispatch.QUEUED -> say("Starting $label as soon as the current run finishes.")
            Dispatch.FAILED -> say("Could not reach Termux. Tap Refresh.")
            else -> Unit
        }
    }

    private suspend fun handle(completion: Completion) {
        val result = completion.result
        // One parse of one stream, off the main thread. Every view below is derived from it.
        val parsed = withContext(Dispatchers.Default) { Protocol.parse(result.stdout) }
        val fromUser = completion.origin == Origin.USER

        // The supervisor polls through the same transport; its result must not overwrite the
        // record of what the user actually just did.
        if (fromUser) {
            _state.update { it.copy(raw = result.stdout, steps = parsed.steps) }
            persistSteps(parsed.steps)
        }

        if (result.exitCode != 0 || result.errmsg.isNotBlank()) {
            val failure =
                withContext(Dispatchers.Default) {
                    parsed.failure(result.exitCode, result.stderr, result.errmsg)
                } ?: Protocol.Failure("It did not finish (exit ${result.exitCode})")
            _state.update { it.copy(failure = failure) }
            persistFailure(failure)
            if (fromUser) {
                say(if (completion.label.isBlank()) "That did not finish" else "${completion.label} did not finish")
                refreshAfterRun(completion.actionId)
            }
            // This is the only place a tool can be marked as needing attention. The old code
            // returned from the error branch *before* this line, so `failedTools` was never
            // populated and the "Last attempt failed" group could not appear at all.
            markFailed(completion, failed = true)
            maybeRequestCatalog()
            return
        }

        // Only a successful *action* clears a failure. A status read proves the device
        // answers, not that the failed step now works — the first version of the post-run
        // refresh erased the banner it existed to show.
        if (fromUser && completion.actionId.isNotBlank()) {
            _state.update { it.copy(failure = null) }
            persistFailure(null)
        }
        if (fromUser) say(completionMessage(completion, parsed))
        markFailed(completion, failed = false)

        // Route on the payload, not on which button was pressed: a probe result is still in
        // flight state when the screen first composes, so responses can overlap.
        if (parsed.actions.isNotEmpty()) {
            _state.update { it.copy(actions = parsed.actions) }
            return
        }

        // A snapshot may fill the screens unless it came from the supervisor. The supervisor
        // polls `--fast` and only ever needs a verdict, so its payload is not the screen's
        // source of truth; everything else (probe, refresh, a user's own read) is.
        //
        // `--fast` no longer disqualifies a snapshot because presence now comes from
        // `tools.installed` (see Protocol.Snapshot.isInstalled) rather than from a version
        // string. The version strings are merged below, not taken at face value.
        if (completion.origin != Origin.SYSTEM) {
            parsed.snapshot?.let { fresh ->
                // A `--fast` read blanks every version string, so it is merged into what is
                // already on screen instead of replacing it. Replacing was how the OpenClaw row
                // (and the installed-tool set) disappeared right after the startup probe.
                val snap = if (completion.fast) fresh.mergedWith(_state.value.snapshot) else fresh
                val at = System.currentTimeMillis()
                _state.update {
                    it.copy(snapshot = snap, checkedAt = at, lastFullAt = if (completion.fast) it.lastFullAt else at)
                }
                Prefs.setLastStatusAt(at)
                // Only a full read is cached. The file is what paints the first frame after a
                // cold start, and a `--fast` document has no versions to paint: saving it made
                // the OpenClaw row disappear on the *next* launch even though the merge above
                // had preserved it in memory.
                if (!completion.fast) viewModelScope.launch { StatusStore.save(app, result.stdout) }
                Prefs.setInstalledTools(snap.installedKeys())
            }
        }

        // A finished run makes every screen stale. Refresh by itself, with a distinct origin
        // so this neither clears the banner nor overwrites the run's raw stream.
        if (fromUser) refreshAfterRun(completion.actionId)

        // Last: the catalogue only makes sense once an idle status has been parsed. If the
        // refresh above took the transport slot, [maybeRequestCatalog] skips and the
        // completion handler for *that* run will ask instead.
        maybeRequestCatalog()
    }

    /**
     * What to say when a run finishes.
     *
     * The cleanup action reports what it removed, and that number is the only proof it did
     * anything: on 8x the same action said "done" while removing nothing (the tree was already
     * gone), which reads identically to success. "Reclaimed 12.9 GB" does not.
     */
    private fun completionMessage(
        completion: Completion,
        parsed: Protocol.Parsed,
    ): String {
        val label = if (completion.label.isBlank()) "Done" else "${completion.label} — done"
        val reclaimed = parsed.reclaimed ?: return label
        val (mb, shims) = reclaimed
        if (mb <= 0 && shims <= 0) return "Nothing to remove — already clean"
        val size =
            when {
                mb >= 1024 -> String.format(java.util.Locale.US, "%.1f GB", mb / 1024.0)
                else -> "$mb MB"
            }
        return "Reclaimed $size, removed $shims shortcut(s)"
    }

    private fun markFailed(
        completion: Completion,
        failed: Boolean,
    ) {
        if (completion.origin != Origin.USER || completion.actionId.isBlank()) return
        Prefs.markFailed(completion.actionId.substringBefore('.'), failed)
    }

    private fun refreshAfterRun(actionId: String) {
        if (Runner.running.value) return
        Runner.send(app, RefreshPolicy.argsAfterRun(actionId), Origin.REFRESH, "Refresh")
    }

    /**
     * Ask for the catalog once the device is idle.
     *
     * The latch is set only when the request was actually dispatched. It used to be set *before*
     * `send`, and a SYSTEM send is skipped when another run holds the transport — on a phone
     * where the supervisor's first `--fast` poll lands in the same instant as the startup probe,
     * that one skipped request latched "already asked" and Packages stayed on "0 of 0 installed"
     * for the life of the process.
     */
    private fun maybeRequestCatalog() {
        val current = _state.value
        if (catalogRequested || current.snapshot == null || current.actions.isNotEmpty()) return
        if (Runner.running.value) return
        when (Runner.send(app, listOf("--api", "list"), Origin.SYSTEM, "Read the tool list")) {
            // Anything but a skip decides the question: either it is on its way, or Termux
            // could not be started at all and retrying in a loop helps nobody.
            Dispatch.SENT, Dispatch.FAILED -> catalogRequested = true
            // The slot was taken (probe, supervisor poll, or a queued tap): try again when that
            // run completes, which is what the completion handler does.
            Dispatch.SKIPPED, Dispatch.QUEUED -> Unit
        }
    }

    /**
     * The user opened Packages and it is still empty: allow one more attempt.
     *
     * Belt and braces on top of the retry above — a screen that says "Reading the tool list…"
     * forever is worse than a slightly eager request, and opening the tab is an explicit ask.
     */
    fun onCatalogScreenOpened() {
        if (_state.value.actions.isEmpty()) catalogRequested = false
        maybeRequestCatalog()
    }

    /**
     * The Tools screen is open: it is the one place a version string is read off the screen.
     *
     * Opening it is therefore the moment to spend the slow read — not app launch, which only
     * needs device facts and service state. Rate-limited by [RefreshPolicy.needsFullRead] so
     * flicking between tabs is free.
     */
    fun onToolsScreenOpened() {
        val current = _state.value
        if (!RefreshPolicy.needsFullRead(System.currentTimeMillis(), current.lastFullAt)) return
        // A full read is what a user's Refresh does too; it must not queue a second one behind
        // itself, and it must not steal the slot from a running install.
        if (Runner.running.value) return
        dispatch(listOf("--api", "status"), "Read tool versions")
    }

    private fun startClock() {
        if (clock?.isActive == true) return
        clock =
            viewModelScope.launch {
                while (isActive) {
                    val elapsed = ((System.currentTimeMillis() - Runner.startedAt.value) / 1000).coerceAtLeast(0)
                    // One small file read per second while a run is in flight, off the main
                    // thread: this is the only way to know what the engine is doing, and it is
                    // skipped entirely when shared storage is not set up.
                    val step = withContext(Dispatchers.IO) { Progress.latest(app) }
                    _state.update {
                        it.copy(
                            elapsedSeconds = elapsed,
                            progress =
                                step?.takeIf { p ->
                                    p.state ==
                                        "running"
                                },
                        )
                    }
                    // The ceiling is per caller, so a 40-minute install is not mistaken for a
                    // dead one — but a genuinely wedged run still gets cleared.
                    Runner.checkCeiling()
                    delay(1000)
                }
            }
    }

    private fun stopClock() {
        clock?.cancel()
        clock = null
        _state.update { it.copy(elapsedSeconds = 0L, progress = null) }
    }

    // ---- process death ------------------------------------------------------------------

    /**
     * The two things worth restoring after the process is killed.
     *
     * A rotation is handled by the ViewModel itself. Process death is not: the app is exactly
     * the kind of process Android kills on a 1.8 GB phone, and coming back to a screen that has
     * forgotten *why* it was showing a red banner (or which steps ran) is how a user re-runs an
     * install that had already failed for a known reason.
     *
     * Deliberately **not** restored: the raw stream (capped at 512 KB and re-derivable from the
     * next run) and the snapshot (a file, re-read on IO by [StatusStore]).
     */
    private fun restoreAfterProcessDeath() {
        saved.get<String>(K_FAILURE_HEADLINE)?.let { headline ->
            val details = saved.get<Array<String>>(K_FAILURE_DETAILS)?.toList().orEmpty()
            _state.update { it.copy(failure = Protocol.Failure(headline, details)) }
        }

        saved.get<Array<String>>(K_STEPS)?.let { rows ->
            val steps =
                rows.mapNotNull { row ->
                    val f = row.split(SEP)
                    if (f.size != 4) {
                        null
                    } else {
                        Protocol.Step(id = f[0], title = f[1], state = f[2], ms = f[3].toLongOrNull() ?: 0L)
                    }
                }
            if (steps.isNotEmpty()) _state.update { it.copy(steps = steps) }
        }
    }

    private fun persistFailure(failure: Protocol.Failure?) {
        saved[K_FAILURE_HEADLINE] = failure?.headline
        saved[K_FAILURE_DETAILS] = failure?.details?.toTypedArray()
    }

    private fun persistSteps(steps: List<Protocol.Step>) {
        saved[K_STEPS] = steps.map { "${it.id}$SEP${it.title}$SEP${it.state}$SEP${it.ms}" }.toTypedArray()
    }

    private companion object {
        const val K_FAILURE_HEADLINE = "failure.headline"
        const val K_FAILURE_DETAILS = "failure.details"
        const val K_STEPS = "run.steps"

        /** Unit separator: can never appear in a step title or id. */
        const val SEP = "\u001F"
    }
}

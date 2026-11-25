package dev.droidai.launcher

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow

data class RunResult(
    val stdout: String,
    val stderr: String,
    val exitCode: Int,
    val err: Int,
    val errmsg: String,
) {
    val ok: Boolean get() = exitCode == 0 && errmsg.isBlank()
}

/**
 * Who asked for the in-flight command.
 *
 * One command at a time is a hard constraint of the transport (a background
 * RUN_COMMAND with a single result PendingIntent), but the three callers must not be
 * treated as equal: the supervisor polls every 60 s, and when its poll held the slot
 * a tap on Install was dropped with no message at all. A user action is queued
 * behind whatever is running instead; the supervisor and the startup probe simply
 * skip their turn.
 */
enum class Origin {
    PROBE,
    USER,
    SYSTEM,

    /**
     * A status read the app issued by itself, after a run finished.
     *
     * It is not SYSTEM, because only a full snapshot may update the screens and the
     * supervisor polls `--fast` (blank versions). It is not USER either: it must not
     * overwrite the raw stream, the step list or the failure notice of the run the user
     * just watched.
     */
    REFRESH,
}

sealed interface Dispatch {
    /** Went to Termux. */
    data object SENT : Dispatch

    /** Another command was in flight; this one will be sent when it finishes. */
    data object QUEUED : Dispatch

    /** Another command was in flight and this caller does not queue. */
    data object SKIPPED : Dispatch

    /** Could not start the Termux service at all. */
    data object FAILED : Dispatch
}

/**
 * A finished run, as an event rather than as state.
 *
 * The UI used to observe [Runner.result] (a `StateFlow`) from a `LaunchedEffect`, which is
 * wrong in two ways: a `StateFlow` conflates, so a supervisor poll landing next to a user
 * action could drop one; and the effect is keyed on the result, so a rotation re-ran the
 * whole handler on the stale value — including the post-run status refresh.
 *
 * [origin] and [actionId] are captured at completion rather than read back from the
 * object, so a queued run dispatched immediately afterwards cannot relabel this one.
 */
data class Completion(
    val result: RunResult,
    val origin: Origin,
    val actionId: String,
    val label: String,
    val startedAt: Long,
    /**
     * The run asked for `--fast`.
     *
     * The client has to know this to merge rather than replace: a `--fast` status carries blank
     * version strings by design, so treating it like a full read deletes what the screen knows.
     * Derived from the arguments at dispatch time, because the result bundle says nothing about
     * how the command was invoked.
     */
    val fast: Boolean = false,
)

/**
 * One in-flight command at a time.
 *
 * Feedback arrives as a Broadcast from the PendingIntent we attach, because a
 * background RUN_COMMAND has no TTY and the result bundle is the only channel
 * that works without shared storage (Termux cannot write into our app dir on
 * Android 10+, and we cannot write into Termux's).
 */
object Runner {
    private const val TAG = "DroidAI"
    private const val ACTION_RESULT = "dev.droidai.launcher.RESULT"
    private const val REQUEST_CODE = 1001

    /** Base of the per-run PendingIntent request codes, so two runs cannot share a PI. */
    private const val REQUEST_CODE_RUNS = 2000
    private const val MAX_RUN_SLOTS = 900

    /** Which run a delivered result belongs to. Carried in the base Intent's action *and* extras. */
    private const val EXTRA_RUN_SLOT = "dev.droidai.launcher.RUN_SLOT"

    /** How long each caller may stay silent before we call it dead. */
    private const val PROBE_CEILING_MS = 25_000L
    private const val SYSTEM_CEILING_MS = 90_000L

    /** Retained stream cap: head and tail, because a long install must not live forever. */
    private const val MAX_STREAM_CHARS = 512 * 1024
    private const val HEAD_CHARS = 128 * 1024

    /** A post-run status refresh is a full read (versions included), so allow the slow one. */
    private const val REFRESH_CEILING_MS = 120_000L

    /**
     * A user action is never timed out on a budget short enough to interrupt real
     * work. Installing Hermes or OpenClaw on a phone takes 10-40 minutes; the old
     * 30 s deadline fired in the middle of it, showed a red failure, and let the user
     * press Install again — two installs racing over one pnpm store. This ceiling
     * only exists so a genuinely wedged run can be cleared.
     */
    private const val USER_CEILING_MS = 60L * 60 * 1000

    /**
     * Completed runs, delivered once.
     *
     * `extraBufferCapacity` matters: the consumer parses the stream off the main thread, so
     * a completion can arrive while the previous one is still being handled. A `StateFlow`
     * would have silently kept only the newest; `DROP_OLDEST` only under a burst of nine.
     */
    private val _completions =
        MutableSharedFlow<Completion>(
            replay = 0,
            extraBufferCapacity = 8,
            onBufferOverflow = BufferOverflow.DROP_OLDEST,
        )
    val completions: SharedFlow<Completion> = _completions.asSharedFlow()

    /**
     * The newest result, for `withTimeoutOrNull { … first() }` awaits.
     *
     * Kept **only** for that pattern (the supervisor has no other channel back), because
     * replaying the current value is what makes the await race-free. Everything that
     * handles a result as an event uses [completions] instead.
     */
    private val _result = MutableStateFlow<RunResult?>(null)
    val result: StateFlow<RunResult?> = _result

    private val _running = MutableStateFlow(false)
    val running: StateFlow<Boolean> = _running

    /** Wall-clock start of the in-flight run, so the UI can show that it is alive. */
    private val _startedAt = MutableStateFlow(0L)
    val startedAt: StateFlow<Long> = _startedAt

    /** What the in-flight run was asked to do, for a completion message. */
    private val _label = MutableStateFlow("")
    val label: StateFlow<String> = _label

    /** Catalog action id of the in-flight run ("" for a plain status read). */
    @Volatile
    private var actionId: String = ""

    /** Whether the in-flight run asked for `--fast`; captured at dispatch, see [Completion.fast]. */
    @Volatile
    private var fast: Boolean = false

    @Volatile
    private var origin = Origin.SYSTEM

    /** A user action that arrived while something else was running. */
    private var queuedArgs: List<String>? = null
    private var queuedLabel: String = ""

    /**
     * Serialises the whole transport.
     *
     * `send` is a check-then-act on [_running] and [_result], and it is called from the UI
     * thread *and* from the supervisor's coroutine. Without a lock, a supervisor tick that
     * raced a tap could dispatch two RUN_COMMANDs through one `REQUEST_CODE` — the second
     * PendingIntent replaces the first, so one result vanished, and the first completion
     * cleared `running` while the second run was still going (buttons re-enabled mid-install).
     */
    private val lock = Any()

    /**
     * Identity of the in-flight run (0 = this process dispatched nothing).
     *
     * Only meaningful for results: a result whose slot is not this one is a run that outlived
     * the process, and folding it into the current run is how "Last run" could show an install
     * log under a status refresh.
     */
    private var runSlot = 0

    fun ceilingFor(o: Origin): Long =
        when (o) {
            Origin.PROBE -> PROBE_CEILING_MS
            Origin.SYSTEM -> SYSTEM_CEILING_MS
            Origin.USER -> USER_CEILING_MS
            Origin.REFRESH -> REFRESH_CEILING_MS
        }

    /**
     * Start a run, or queue it behind the one in flight.
     *
     * Safe to call from any thread (see [lock]); the result comes back on [completions].
     */
    fun send(
        context: Context,
        args: List<String>,
        o: Origin = Origin.USER,
        label: String = "",
    ): Dispatch =
        synchronized(lock) {
            if (_running.value) {
                if (o == Origin.USER) {
                    queuedArgs = args
                    queuedLabel = label
                    return@synchronized Dispatch.QUEUED
                }
                return@synchronized Dispatch.SKIPPED
            }
            dispatchLocked(context, args, o, label)
        }

    private fun dispatchLocked(
        context: Context,
        args: List<String>,
        o: Origin,
        label: String,
    ): Dispatch {
        origin = o
        _label.value = label
        actionId = if (args.size >= 3 && args[1] == "run") args[2] else ""
        fast = args.contains("--fast")
        _startedAt.value = System.currentTimeMillis()
        _running.value = true
        _result.value = null

        // A distinct PendingIntent per run.
        //
        // With one shared request code, `FLAG_UPDATE_CURRENT` rewrote the base Intent every
        // dispatch, so a result from a run that outlived the process (an install finishing after
        // Android killed the app) arrived looking exactly like the *current* run's result and was
        // attributed to it. Now the base Intent names the run, and [deliver] refuses a result that
        // belongs to a run this process no longer owns.
        runSlot = (runSlot % MAX_RUN_SLOTS) + 1
        val slot = runSlot
        val receiver =
            Intent(context, TermuxResultReceiver::class.java)
                .setAction("$ACTION_RESULT.$slot")
                .putExtra(EXTRA_RUN_SLOT, slot)
        val flags =
            PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
        val pending = PendingIntent.getBroadcast(context, REQUEST_CODE_RUNS + slot, receiver, flags)
        val intent = Termux.buildIntent(args, pending)

        val started =
            runCatching { context.startService(intent) }.isSuccess ||
                runCatching { ContextCompat.startForegroundService(context, intent) }.isSuccess

        if (!started) {
            _running.value = false
            _result.value = RunResult("", "", -1, -1, "Could not start the Termux service")
            return Dispatch.FAILED
        }
        return Dispatch.SENT
    }

    /**
     * Give up on a run that went silent past its caller's ceiling.
     *
     * Without this, a result that never arrives leaves `_running` true forever, and
     * because send() refuses to dispatch while running, every Retry is a no-op. The
     * ceiling is per caller (see [ceilingFor]) so that a slow install is not mistaken
     * for a dead one.
     */
    fun checkCeiling() {
        val finished = synchronized(lock) { timedOutLocked() } ?: return
        _completions.tryEmit(finished)
        synchronized(lock) { flushQueueLocked() }
    }

    /** @return the completion to publish, or null when the run is still within its budget. */
    private fun timedOutLocked(): Completion? {
        if (!_running.value) return null
        val elapsed = System.currentTimeMillis() - _startedAt.value
        if (elapsed < ceilingFor(origin)) return null
        val secs = elapsed / 1000
        val wasProbe = origin == Origin.PROBE
        val finished = abandonLocked("Termux did not respond within ${secs}s", wasProbe)
        return finished
    }

    private fun abandonLocked(
        message: String,
        wasProbe: Boolean,
    ): Completion {
        val finished = RunResult(stdout = "", stderr = "", exitCode = -1, err = -1, errmsg = message)
        val done = Completion(finished, origin, actionId, _label.value, _startedAt.value, fast)
        _running.value = false
        _result.value = finished
        if (wasProbe) {
            Gate.probe.value = Probe.UNREACHABLE
            Gate.detail.value = message
        }
        return done
    }

    fun deliver(intent: Intent) {
        val bundle = intent.getBundleExtra(Termux.RESULT_BUNDLE)
        val result =
            RunResult(
                stdout = clip(bundle?.getString(Termux.R_STDOUT) ?: ""),
                stderr = clip(bundle?.getString(Termux.R_STDERR) ?: ""),
                exitCode = bundle?.getInt(Termux.R_EXIT) ?: -1,
                err = bundle?.getInt(Termux.R_ERR) ?: -1,
                errmsg = bundle?.getString(Termux.R_ERRMSG) ?: "",
            )

        val deliveredFrom = deliveredSlot(intent)

        // State settles under the lock; the completion is published *outside* it, so no
        // collector can resume inside a critical section — `Dispatchers.Main.immediate` may
        // run a resumed coroutine on the emitting thread.
        val done =
            synchronized(lock) {
                // A result for a run this process no longer owns is dropped, not attributed: the
                // app may have been killed mid-install, and the run that arrives later is not the
                // one the UI is showing. A result arriving with nothing in flight is the same
                // case (the ceiling already abandoned it).
                if (deliveredFrom > 0 && deliveredFrom != runSlot) {
                    Log.w(TAG, "ignoring a result from run $deliveredFrom (current: $runSlot)")
                    return
                }
                if (!_running.value) {
                    Log.w(TAG, "ignoring a result with nothing in flight")
                    return
                }

                val completion = Completion(result, origin, actionId, _label.value, _startedAt.value, fast)
                _result.value = result
                _running.value = false
                if (origin == Origin.PROBE) classify(result)
                completion
            }
        _completions.tryEmit(done)
        synchronized(lock) { flushQueueLocked() }
    }

    /**
     * The run slot a broadcast carries, or 0 when it cannot be told.
     *
     * Termux sends the result by `pendingIntent.send(..., intent)`, and how much of the base
     * Intent survives that merge is platform detail — so the slot travels in both the action and
     * an extra, and 0 means "unknown", which is treated as current rather than dropped.
     */
    private fun deliveredSlot(intent: Intent): Int {
        val extra = intent.getIntExtra(EXTRA_RUN_SLOT, 0)
        if (extra > 0) return extra
        val fromAction = intent.action?.substringAfterLast('.')?.toIntOrNull() ?: return 0
        // The legacy action (no slot) ends in RESULT, so a non-numeric suffix is "unknown".
        return if (fromAction > 0) fromAction else 0
    }

    /**
     * Keep at most [MAX_STREAM_CHARS], from both ends.
     *
     * The head is kept because `step` events for early steps are emitted once, and the
     * tail because failures, log replays and the final steps are at the end. A 40-minute
     * install otherwise stays resident in the process three times over (the result, the
     * ViewModel's raw buffer, the parsed events).
     */
    private fun clip(stream: String): String {
        if (stream.length <= MAX_STREAM_CHARS) return stream
        val head = stream.substring(0, HEAD_CHARS)
        val tail = stream.substring(stream.length - (MAX_STREAM_CHARS - HEAD_CHARS))
        return "$head\n… (middle of this output was trimmed to keep the app's memory bounded) …\n$tail"
    }

    /**
     * Which gate actually failed.
     *
     * The old check was `exitCode == 0 && stdout contains "t":"data"`, and every
     * other outcome fell through to the allow-external-apps screen. A device with no
     * toolkit therefore got told to edit termux.properties — an instruction that
     * cannot fix it, on the one screen a new user is guaranteed to see.
     */
    private fun classify(result: RunResult) {
        val probe = Gate.classify(result.exitCode, result.stdout, result.stderr, result.errmsg)
        if (probe == Probe.READY) {
            Gate.probe.value = Probe.READY
            Gate.detail.value = ""
            Gate.message.value = ""
            Gate.fix.value = ""
            // Remember success: the next launch opens on the Overview instead of spending
            // the probe's ten seconds on a loading screen for a device that already works.
            Prefs.setTermuxReady(true)
            return
        }

        Prefs.setTermuxReady(false)

        // The engine writes its errors for a person. Use its sentence as the screen's body and
        // its hint as the remedy, instead of an apology plus a collapsed details block.
        val error = Protocol.events(result.stdout).firstOrNull { it.optString("t") == "error" }
        val engineMessage = error?.optString("msg").orEmpty()
        val engineHint = error?.optString("hint").orEmpty()
        val engineDetail = error?.optString("detail").orEmpty()

        Gate.message.value = engineMessage
        Gate.fix.value =
            engineHint.ifBlank {
                if (probe == Probe.NEEDS_PACKAGES) "apt update && apt full-upgrade && apt install -y jq" else ""
            }
        Gate.probe.value = probe
        Gate.detail.value =
            listOfNotNull(
                engineMessage.takeIf { it.isNotBlank() },
                engineDetail.takeIf { it.isNotBlank() },
                summarise(result),
            ).joinToString("\n")
    }

    /** Three lines, exit code included: the gate has to be diagnosable, not just red. */
    private fun summarise(result: RunResult): String {
        val text =
            result.errmsg
                .ifBlank { result.stderr }
                .ifBlank { result.stdout }
                .trim()
        val head =
            text
                .lineSequence()
                .filter { it.isNotBlank() }
                .take(3)
                .joinToString(" / ")
                .take(300)
        return "exit=${result.exitCode} err=${result.err} " +
            if (head.isBlank()) "(no output and no error text)" else head
    }

    private fun flushQueueLocked() {
        val next = queuedArgs ?: return
        queuedArgs = null
        val context = appContext ?: return
        dispatchLocked(context, next, Origin.USER, queuedLabel)
    }

    /**
     * The application context, so a queued action can be flushed from the receiver
     * (which has no Activity). Set on the first send.
     */
    @Volatile
    private var appContext: Context? = null

    fun attach(context: Context) {
        if (appContext == null) appContext = context.applicationContext
    }
}

class TermuxResultReceiver : BroadcastReceiver() {
    override fun onReceive(
        context: Context,
        intent: Intent,
    ) {
        Runner.attach(context)
        Runner.deliver(intent)
    }
}

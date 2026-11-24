package dev.droidai.launcher

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
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
    private const val ACTION_RESULT = "dev.droidai.launcher.RESULT"
    private const val REQUEST_CODE = 1001

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
        _startedAt.value = System.currentTimeMillis()
        _running.value = true
        _result.value = null

        val receiver = Intent(context, TermuxResultReceiver::class.java).setAction(ACTION_RESULT)
        val flags =
            PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
        val pending = PendingIntent.getBroadcast(context, REQUEST_CODE, receiver, flags)
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
        val done = Completion(finished, origin, actionId, _label.value, _startedAt.value)
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

        // State settles under the lock; the completion is published *outside* it, so no
        // collector can resume inside a critical section — `Dispatchers.Main.immediate` may
        // run a resumed coroutine on the emitting thread.
        val done =
            synchronized(lock) {
                val completion = Completion(result, origin, actionId, _label.value, _startedAt.value)
                _result.value = result
                _running.value = false
                if (origin == Origin.PROBE) classify(result)
                completion
            }
        _completions.tryEmit(done)
        synchronized(lock) { flushQueueLocked() }
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
        val all = "${result.errmsg}\n${result.stderr}\n${result.stdout}"
        val lower = all.lowercase()

        if (result.exitCode == 0 && result.stdout.contains("\"t\":\"data\"")) {
            Gate.probe.value = Probe.READY
            Gate.detail.value = ""
            // Remember success: the next launch opens on the Overview instead of spending
            // the probe's ten seconds on a loading screen for a device that already works.
            Prefs.setTermuxReady(true)
            return
        }

        Prefs.setTermuxReady(false)
        Gate.probe.value =
            when {
                lower.contains("allow-external-apps") -> Probe.DENIED
                lower.contains("toolkit not found") ||
                    lower.contains("first-run setup") ||
                    lower.contains("lib/ not found") -> Probe.NO_TOOLKIT
                result.stdout.isBlank() && result.stderr.isBlank() && result.errmsg.isBlank() ->
                    Probe.UNREACHABLE
                else -> Probe.ERROR
            }
        Gate.detail.value = summarise(result)
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

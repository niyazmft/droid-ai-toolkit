package dev.droidai.launcher

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.content.ContextCompat
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

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

    /**
     * A user action is never timed out on a budget short enough to interrupt real
     * work. Installing Hermes or OpenClaw on a phone takes 10-40 minutes; the old
     * 30 s deadline fired in the middle of it, showed a red failure, and let the user
     * press Install again — two installs racing over one pnpm store. This ceiling
     * only exists so a genuinely wedged run can be cleared.
     */
    private const val USER_CEILING_MS = 60L * 60 * 1000

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
    private var actionId: String = ""

    fun lastActionId(): String = actionId

    private var origin = Origin.SYSTEM

    /** A user action that arrived while something else was running. */
    private var queuedArgs: List<String>? = null
    private var queuedLabel: String = ""

    fun ceilingFor(o: Origin): Long =
        when (o) {
            Origin.PROBE -> PROBE_CEILING_MS
            Origin.SYSTEM -> SYSTEM_CEILING_MS
            Origin.USER -> USER_CEILING_MS
        }

    /** Who the last dispatched run belonged to. The UI uses it to ignore supervisor polls. */
    fun lastOrigin(): Origin = origin

    fun send(
        context: Context,
        args: List<String>,
        o: Origin = Origin.USER,
        label: String = "",
    ): Dispatch {
        if (_running.value) {
            if (o == Origin.USER) {
                queuedArgs = args
                queuedLabel = label
                return Dispatch.QUEUED
            }
            return Dispatch.SKIPPED
        }
        return dispatch(context, args, o, label)
    }

    private fun dispatch(
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
        if (!_running.value) return
        val elapsed = System.currentTimeMillis() - _startedAt.value
        if (elapsed < ceilingFor(origin)) return
        val secs = elapsed / 1000
        val wasProbe = origin == Origin.PROBE
        abandon("Termux did not respond within ${secs}s", wasProbe)
    }

    private fun abandon(
        message: String,
        wasProbe: Boolean,
    ) {
        _running.value = false
        _result.value = RunResult("", "", -1, -1, message)
        if (wasProbe) {
            Gate.probe.value = Probe.UNREACHABLE
            Gate.detail.value = message
        }
        flushQueue()
    }

    fun deliver(intent: Intent) {
        val bundle = intent.getBundleExtra(Termux.RESULT_BUNDLE)
        val result =
            RunResult(
                stdout = bundle?.getString(Termux.R_STDOUT) ?: "",
                stderr = bundle?.getString(Termux.R_STDERR) ?: "",
                exitCode = bundle?.getInt(Termux.R_EXIT) ?: -1,
                err = bundle?.getInt(Termux.R_ERR) ?: -1,
                errmsg = bundle?.getString(Termux.R_ERRMSG) ?: "",
            )
        _result.value = result
        _running.value = false

        if (origin == Origin.PROBE) classify(result)
        flushQueue()
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

    private fun flushQueue() {
        val next = queuedArgs ?: return
        queuedArgs = null
        val context = appContext ?: return
        dispatch(context, next, Origin.USER, queuedLabel)
    }

    /**
     * The application context, so a queued action can be flushed from the receiver
     * (which has no Activity). Set on the first send.
     */
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

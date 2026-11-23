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

    private val _result = MutableStateFlow<RunResult?>(null)
    val result: StateFlow<RunResult?> = _result

    private val _running = MutableStateFlow(false)
    val running: StateFlow<Boolean> = _running

    private var isProbe = false

    /**
     * Returns true when the command was actually dispatched. Callers that chain
     * requests must check this: a call while another command is in flight is
     * dropped, and silently assuming success is how the catalog request went
     * missing.
     */
    fun send(
        context: Context,
        args: List<String>,
        isProbe: Boolean = false,
    ): Boolean {
        if (_running.value) return false
        this.isProbe = isProbe
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
            return false
        }
        return true
    }

    /**
     * Give up on the in-flight command.
     *
     * Without this, a result that never arrives leaves `_running` true forever —
     * and because send() refuses to dispatch while running, every later attempt
     * (including Retry) is silently dropped. The UI then sits on a gate that
     * cannot be cleared and looks broken.
     */
    fun timeout(seconds: Int) {
        if (!_running.value) return
        _running.value = false
        _result.value = RunResult("", "", -1, -1, "Termux did not respond within $seconds s")
        if (isProbe) {
            Gate.termuxUnresponsive.value = false
            Gate.probeOk.value = false
            Gate.probeMessage.value = "Termux did not respond within $seconds s"
            Gate.termuxUnresponsive.value = true
        }
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

        if (isProbe) {
            // The probe doubles as the allow-external-apps check: Termux refuses
            // the intent outright (with an errmsg) when the property is off, so a
            // successful `data` event means every gate is open.
            Gate.probeOk.value = result.exitCode == 0 && result.stdout.contains("\"t\":\"data\"")
            Gate.probeMessage.value =
                if (Gate.probeOk.value == true) {
                    ""
                } else {
                    // Never just "it did not work": exit code, err code and whichever
                    // stream has text are what make the gate diagnosable.
                    val detail =
                        result.errmsg
                            .ifBlank { result.stderr }
                            .ifBlank { result.stdout }
                            .trim()
                    val head =
                        detail
                            .lineSequence()
                            .take(3)
                            .joinToString(" / ")
                            .take(300)
                    "exit=${result.exitCode} err=${result.err} " +
                        if (head.isBlank()) "(no output and no error text)" else head
                }
        }
    }
}

class TermuxResultReceiver : BroadcastReceiver() {
    override fun onReceive(
        context: Context,
        intent: Intent,
    ) = Runner.deliver(intent)
}

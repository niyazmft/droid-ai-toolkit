package dev.droidai.launcher

import android.content.Context
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * The onboarding gates, in order. Each one is something the app cannot do for the
 * user:
 *
 *   1. Termux is installed (we can only offer the link)
 *   2. the RUN_COMMAND permission is granted (a system dialog)
 *   3. allow-external-apps is true (only Termux can write its own properties)
 *
 * Gate 3 is verified by actually sending a command and watching for a result —
 * there is no way to read Termux's private files, and probing is also the honest
 * test of whether the whole chain works.
 *
 * [Probe] is a tri-state and deliberately not a Boolean: while the first status run
 * is still in flight (up to ~10 s on 8x) the app used to render the *failure* screen,
 * so every cold start opened on an alarming "Enable external commands" page with a
 * shell command to type. [Probe.CHECKING] gives the UI a neutral loading state, and
 * the failure kinds are distinct so the app can stop blaming the wrong gate: an
 * empty device has no toolkit, which has nothing to do with allow-external-apps.
 */
enum class Probe {
    /** A status run is in flight; nothing is known yet. */
    CHECKING,
    READY,

    /** Termux answered, but there is no toolkit checkout to run. */
    NO_TOOLKIT,

    /** Termux refused the intent: allow-external-apps is off. */
    DENIED,

    /**
     * Termux is working, but a command-line tool Setup needs could not be installed.
     *
     * Distinct from [ERROR] because it has a remedy the app can print: a clean Termux on
     * Android 16 refused `pkg` (its curl cannot link) and `--api` will not run without jq, so
     * the honest screen is "one package is missing, paste this", not "something went wrong".
     */
    NEEDS_PACKAGES,

    /** Nothing came back at all — Termux's process is gone (LMK) or it is not running. */
    UNREACHABLE,

    /** It answered, and the answer was something else. [Gate.detail] has it. */
    ERROR,
}

object Gate {
    val termuxInstalled = MutableStateFlow(false)
    val permissionGranted = MutableStateFlow(false)

    val probe = MutableStateFlow(Probe.CHECKING)

    /** The engine's own words, for the "technical details" disclosure. Never the only message. */
    val detail = MutableStateFlow("")

    /**
     * One sentence from the engine that a person can act on, when it sent one.
     *
     * The engine writes these for humans ("jq is required for the --api interface"), so the
     * screens use them as the body instead of a generic apology plus a hidden details block.
     */
    val message = MutableStateFlow("")

    /** The exact line that fixes [NEEDS_PACKAGES], from the engine's `hint` when it offers one. */
    val fix = MutableStateFlow("")

    fun refresh(context: Context) {
        termuxInstalled.value =
            runCatching {
                context.packageManager.getPackageInfo(Termux.PKG, 0)
            }.isSuccess

        permissionGranted.value =
            ContextCompat.checkSelfPermission(context, Termux.PERMISSION) ==
            PackageManager.PERMISSION_GRANTED
    }

    fun resetProbe() {
        probe.value = Probe.CHECKING
        detail.value = ""
        message.value = ""
        fix.value = ""
    }

    /**
     * Which gate failed, decided from the engine's own reply.
     *
     * Pure and public so it can be unit-tested: this mapping is what turned "jq is required for
     * the --api interface" into a generic "something went wrong" on a clean Android 16 device.
     * Order matters — READY first, and the prerequisite markers before the allow-external-apps
     * text, which can also appear in unrelated output.
     */
    fun classify(
        exitCode: Int,
        stdout: String,
        stderr: String,
        errmsg: String,
    ): Probe {
        val lower = "$errmsg\n$stderr\n$stdout".lowercase()
        return when {
            exitCode == 0 && stdout.contains("\"t\":\"data\"") -> Probe.READY
            lower.contains("missing-packages:") || lower.contains("jq is required") -> Probe.NEEDS_PACKAGES
            lower.contains("allow-external-apps") -> Probe.DENIED
            lower.contains("toolkit not found") ||
                lower.contains("first-run setup") ||
                lower.contains("lib/ not found") -> Probe.NO_TOOLKIT
            stdout.isBlank() && stderr.isBlank() && errmsg.isBlank() -> Probe.UNREACHABLE
            else -> Probe.ERROR
        }
    }
}

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
    }
}

package dev.droidai.launcher

import android.content.Context
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * The three onboarding gates, in order. Each one is something the app cannot do
 * for the user:
 *
 *   1. Termux is installed (we can only offer the link)
 *   2. the RUN_COMMAND permission is granted (a system dialog)
 *   3. allow-external-apps is true (only Termux can write its own properties)
 *
 * Gate 3 is verified by actually sending a command and watching for a result —
 * there is no way to read Termux's private files, and probing is also the honest
 * test of whether the whole chain works.
 */
object Gate {
    val termuxInstalled = MutableStateFlow(false)
    val permissionGranted = MutableStateFlow(false)

    /** null = not probed yet, true = working, false = refused */
    val probeOk = MutableStateFlow<Boolean?>(null)
    val probeMessage = MutableStateFlow("")

    /**
     * True when Termux never answered at all (as opposed to answering "no").
     * Those two failures look identical from outside, and blaming
     * allow-external-apps for an LMK-killed Termux sends the user to the wrong
     * fix. Observed on 8x: Termux was dead while the package and its permission
     * were both still fine.
     */
    val termuxUnresponsive = MutableStateFlow(false)

    fun refresh(context: Context) {
        termuxInstalled.value = runCatching {
            context.packageManager.getPackageInfo(Termux.PKG, 0)
        }.isSuccess

        permissionGranted.value =
            ContextCompat.checkSelfPermission(context, Termux.PERMISSION) ==
                PackageManager.PERMISSION_GRANTED
    }
}

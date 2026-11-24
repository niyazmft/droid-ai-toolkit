package dev.droidai.launcher

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Brings the supervisor back after a reboot.
 *
 * Without this the watchdog only existed from the moment somebody opened the app: the phone
 * restarts, PM2 comes back via the toolkit's `~/.termux/boot/start-pm2.sh`, and the one thing
 * whose entire job is to report "a service is down" stayed dead — the exact silent failure it
 * was built to surface. Verified absent on both test devices before this landed.
 *
 * Deliberate choices:
 *  - it respects [Prefs.supervisorEnabled]; a user who turned the notification off does not get
 *    it back at boot;
 *  - it does **not** start `MainActivity`, so a reboot does not put the app in front of you;
 *  - failures are logged, never thrown: a `BOOT_COMPLETED` receiver that crashes is just a
 *    crash loop the user cannot see.
 *
 * `specialUse` is one of the types a `BOOT_COMPLETED` receiver may start on Android 12+ (the
 * ban applies to `dataSync`/`mediaPlayback`/`mediaProjection`). On Huawei/EMUI the OEM start-up
 * manager can still veto it until the app is allowed under Battery → App launch; that gate is
 * outside the app's control.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(
        context: Context,
        intent: Intent,
    ) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED && action != ACTION_QUICKBOOT) return

        Prefs.init(context)
        if (!Prefs.supervisorEnabled.value) return

        runCatching { SupervisorService.start(context) }
            .onFailure { Log.w(TAG, "could not restore the supervisor after boot", it) }
    }

    private companion object {
        const val TAG = "DroidAI"

        /** Some OEMs (HTC, older EMUI) send this instead of BOOT_COMPLETED. */
        const val ACTION_QUICKBOOT = "android.intent.action.QUICKBOOT_POWERON"
    }
}

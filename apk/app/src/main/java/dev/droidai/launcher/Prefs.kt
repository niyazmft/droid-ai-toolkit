package dev.droidai.launcher

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * App-local preferences.
 *
 * These are behaviours the app itself owns (a dialog, keeping output, whether to retry a
 * gateway). Nothing here changes the engine: anything that would alter install behaviour
 * has to be a spec or an argument, not a hidden switch.
 */
object Prefs {
    private const val FILE = "droid_ai_prefs"
    private const val KEY_AUTO_START = "auto_start_gateway"
    private const val KEY_CONFIRM_REMOVE = "confirm_remove"
    private const val KEY_RETAIN_RAW = "retain_raw"
    private const val KEY_TERMUX_READY = "termux_ready"

    private var store: SharedPreferences? = null

    val autoStartGateway = MutableStateFlow(true)
    val confirmRemove = MutableStateFlow(true)
    val retainRaw = MutableStateFlow(true)

    /**
     * This device has passed the Termux gates at least once.
     *
     * Persisted because every cold start otherwise paid the full probe (~8 s here) on a
     * "Checking your device…" screen before it could show anything. A device that already
     * works should open straight onto the Overview; the probe still runs in the
     * background, and a real failure demotes the flag again.
     */
    val termuxReady = MutableStateFlow(false)

    fun init(context: Context) {
        val prefs = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        store = prefs
        autoStartGateway.value = prefs.getBoolean(KEY_AUTO_START, true)
        confirmRemove.value = prefs.getBoolean(KEY_CONFIRM_REMOVE, true)
        retainRaw.value = prefs.getBoolean(KEY_RETAIN_RAW, true)
        termuxReady.value = prefs.getBoolean(KEY_TERMUX_READY, false)
    }

    fun setTermuxReady(value: Boolean) {
        if (termuxReady.value == value) return
        termuxReady.value = value
        store?.edit()?.putBoolean(KEY_TERMUX_READY, value)?.apply()
    }

    fun setAutoStart(value: Boolean) {
        autoStartGateway.value = value
        store?.edit()?.putBoolean(KEY_AUTO_START, value)?.apply()
    }

    fun setConfirmRemove(value: Boolean) {
        confirmRemove.value = value
        store?.edit()?.putBoolean(KEY_CONFIRM_REMOVE, value)?.apply()
    }

    fun setRetainRaw(value: Boolean) {
        retainRaw.value = value
        store?.edit()?.putBoolean(KEY_RETAIN_RAW, value)?.apply()
    }
}

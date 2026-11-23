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

    private var store: SharedPreferences? = null

    val autoStartGateway = MutableStateFlow(true)
    val confirmRemove = MutableStateFlow(true)
    val retainRaw = MutableStateFlow(true)

    fun init(context: Context) {
        val prefs = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        store = prefs
        autoStartGateway.value = prefs.getBoolean(KEY_AUTO_START, true)
        confirmRemove.value = prefs.getBoolean(KEY_CONFIRM_REMOVE, true)
        retainRaw.value = prefs.getBoolean(KEY_RETAIN_RAW, true)
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

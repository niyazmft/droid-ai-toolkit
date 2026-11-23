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
    private const val KEY_SUPERVISOR = "supervisor_enabled"
    private const val KEY_INSTALLED = "installed_tools"
    private const val KEY_FAILED = "failed_tools"

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

    /**
     * Run the foreground supervisor, which is what puts an always-on notification in the
     * shade.
     *
     * On by default, because the failure this project keeps hitting is the runtime dying
     * silently: Termux is killed, every service stops, and nothing says so. Off is a
     * legitimate choice for someone who finds a permanent notification more annoying than
     * that risk — it is their phone — but it has to be a choice they made, and the
     * subtitle says what it costs.
     */
    val supervisorEnabled = MutableStateFlow(true)

    /**
     * Tools this app has seen installed at least once, by catalog key.
     *
     * Needed because "installed" cannot be read from a `status --fast` snapshot: that form
     * leaves version strings blank by design, and inferring "not installed" from them is
     * how Packages came to claim 0 of 8 on a device with four tools installed. It also
     * gives us the one signal that a tool *disappeared* rather than never existed.
     */
    val installedTools = MutableStateFlow<Set<String>>(emptySet())

    /** Catalog keys whose last install/repair attempt failed on this device. */
    val failedTools = MutableStateFlow<Set<String>>(emptySet())

    fun init(context: Context) {
        val prefs = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        store = prefs
        autoStartGateway.value = prefs.getBoolean(KEY_AUTO_START, true)
        confirmRemove.value = prefs.getBoolean(KEY_CONFIRM_REMOVE, true)
        retainRaw.value = prefs.getBoolean(KEY_RETAIN_RAW, true)
        termuxReady.value = prefs.getBoolean(KEY_TERMUX_READY, false)
        supervisorEnabled.value = prefs.getBoolean(KEY_SUPERVISOR, true)
        installedTools.value = prefs.getStringSet(KEY_INSTALLED, emptySet())?.toSet() ?: emptySet()
        failedTools.value = prefs.getStringSet(KEY_FAILED, emptySet())?.toSet() ?: emptySet()
    }

    fun setInstalledTools(value: Set<String>) {
        if (installedTools.value == value) return
        installedTools.value = value
        store?.edit()?.putStringSet(KEY_INSTALLED, value)?.apply()
    }

    fun markFailed(
        tool: String,
        failed: Boolean,
    ) {
        if (tool.isBlank()) return
        val next = if (failed) failedTools.value + tool else failedTools.value - tool
        if (next == failedTools.value) return
        failedTools.value = next
        store?.edit()?.putStringSet(KEY_FAILED, next)?.apply()
    }

    fun setSupervisorEnabled(value: Boolean) {
        supervisorEnabled.value = value
        store?.edit()?.putBoolean(KEY_SUPERVISOR, value)?.apply()
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

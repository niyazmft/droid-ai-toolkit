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
    private const val KEY_LAST_STATUS = "last_status"
    private const val KEY_LAST_STATUS_AT = "last_status_at"
    private const val KEY_RESTART_ATTEMPTS = "restart_attempts"
    private const val KEY_THEME = "theme_mode"
    private const val KEY_NOTIFICATION_ASKED = "notification_asked"

    /** Theme overrides. Both palettes are designed, so this is a real choice, not a fallback. */
    const val THEME_SYSTEM = "system"
    const val THEME_LIGHT = "light"
    const val THEME_DARK = "dark"

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

    /**
     * When the status document was last taken.
     *
     * The document itself lives in [StatusStore] — a multi-KB JSON blob does not belong in
     * an XML file that is parsed whole on the main thread at startup (D14). This `Long`
     * stays here because `onResume` needs it synchronously to decide whether a refresh is
     * due.
     */
    val lastStatusAt = MutableStateFlow(0L)

    /**
     * Consecutive "nothing is online, try to restart" attempts.
     *
     * Persisted because the supervisor no longer runs on a timer: without this, every
     * unlock would reset the counter and a broken install would be restarted forever.
     */
    val restartAttempts = MutableStateFlow(0)

    /**
     * system | light | dark.
     *
     * Follows the device by default — the palette is designed for both — but the switch
     * exists because a devtool is often wanted dark in a bright room, and checking the
     * dark design should not require changing the whole phone.
     */
    val themeMode = MutableStateFlow(THEME_SYSTEM)

    /**
     * The system notification permission has been asked for at least once.
     *
     * On API 33+ the supervisor's notification is invisible without that grant, which
     * silently defeats the one thing the supervisor exists for. It is asked in context
     * (when the supervisor is on) and exactly once — a permission dialog on every launch
     * is how an app gets its notification channel turned off for good.
     */
    val notificationAsked = MutableStateFlow(false)

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
        lastStatusAt.value = prefs.getLong(KEY_LAST_STATUS_AT, 0L)
        // The status document moved to StatusStore. Remove the leftover payload so the XML
        // file (and therefore every startup read) goes back to being tiny.
        if (prefs.contains(KEY_LAST_STATUS)) prefs.edit().remove(KEY_LAST_STATUS).apply()
        restartAttempts.value = prefs.getInt(KEY_RESTART_ATTEMPTS, 0)
        themeMode.value = prefs.getString(KEY_THEME, THEME_SYSTEM) ?: THEME_SYSTEM
        notificationAsked.value = prefs.getBoolean(KEY_NOTIFICATION_ASKED, false)
    }

    fun setRestartAttempts(value: Int) {
        if (restartAttempts.value == value) return
        restartAttempts.value = value
        store?.edit()?.putInt(KEY_RESTART_ATTEMPTS, value)?.apply()
    }

    fun setLastStatusAt(at: Long) {
        lastStatusAt.value = at
        store?.edit()?.putLong(KEY_LAST_STATUS_AT, at)?.apply()
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

    fun setThemeMode(value: String) {
        if (themeMode.value == value) return
        themeMode.value = value
        store?.edit()?.putString(KEY_THEME, value)?.apply()
    }

    fun setNotificationAsked() {
        if (notificationAsked.value) return
        notificationAsked.value = true
        store?.edit()?.putBoolean(KEY_NOTIFICATION_ASKED, true)?.apply()
    }
}

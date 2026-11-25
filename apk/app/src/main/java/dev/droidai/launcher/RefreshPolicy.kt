package dev.droidai.launcher

/**
 * When a full status read is worth its cost.
 *
 * `status --fast` (≈6 s on y6, 7.2 s on 8x) answers everything the app shows except tool
 * version strings, which is most of the cost: each one starts a whole Node or Python runtime,
 * and a full read measured 10.8 s on y6 / 23.1 s on 8x.
 *
 * So opening the app, unlocking the phone and finishing a service action all use `--fast`,
 * and the full read happens only where versions are actually read off the screen — the Tools
 * screen — or when the user taps Refresh, which is an explicit "measure everything now".
 *
 * Extracted as a pure function because a timer here would be invisible: the difference
 * between "the app refreshes on open" and "the app refreshes on open, expensively" is one
 * word in an argument list, and the only way to notice the wrong one is CPU time.
 */
internal object RefreshPolicy {
    /**
     * How stale a full read may be before opening Tools repeats it.
     *
     * Five minutes is short enough that a tool installed from Termux shows up promptly, and
     * long enough that switching tabs back and forth is free.
     */
    const val FULL_REFRESH_MS = 5 * 60_000L

    /**
     * Does the app need to re-read versions?
     *
     * [lastFullAt] is 0 when this process has never completed a full read, which includes a
     * cold start whose only snapshot came from the cache or from `--fast`.
     */
    fun needsFullRead(
        now: Long,
        lastFullAt: Long,
    ): Boolean = lastFullAt <= 0L || now - lastFullAt >= FULL_REFRESH_MS

    /**
     * The read the app issues by itself once a user action finishes.
     *
     * A service action only changes one boolean — is it online — which `--fast` answers in a
     * third of the time. An install, update, repair or uninstall changes what exists, and the
     * next thing the user looks at is the version string, so those keep the full read.
     *
     * The action id is the only input; the origin (REFRESH) says who asked, not what is needed.
     */
    fun argsAfterRun(actionId: String): List<String> =
        if (actionId.startsWith("service.")) {
            listOf("--api", "status", "--fast")
        } else {
            listOf("--api", "status")
        }
}

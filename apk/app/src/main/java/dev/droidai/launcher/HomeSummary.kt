package dev.droidai.launcher

/**
 * The one sentence and the one button on Home.
 *
 * F3's rule for the first screen: state, then *the next thing to do*. Everything else — the
 * device table, per-service pills, the `adb` remedy, raw output — moved to Advanced, because a
 * first-time reader cannot act on any of it and it all competes with the button they can.
 *
 * Pure and tested because "what should Home say" was previously four separate conditions spread
 * across the screen's markup, and one of them (a device with nothing installed) was actively
 * wrong: it announced that services were down.
 */
internal object HomeSummary {
    enum class Verdict {
        /** No tool installed: nothing is expected to run, so nothing is wrong. */
        NOTHING_INSTALLED,

        /** Tools exist, none is up — the one case worth offering a restart for. */
        NOTHING_RUNNING,

        /** Something failed or a requirement is missing: point at Tools. */
        NEEDS_ATTENTION,

        RUNNING,
    }

    /** What Home's one button does. */
    enum class Action {
        CHOOSE_TOOL,
        RESTART_EVERYTHING,
    }

    fun verdict(
        installed: Int,
        running: Int,
        needsAttention: Boolean,
    ): Verdict =
        when {
            // Online services decide first: a device can serve from a package this build does
            // not recognise, and calling that "nothing running" would be a lie on a working phone.
            running > 0 -> Verdict.RUNNING
            installed == 0 -> Verdict.NOTHING_INSTALLED
            needsAttention -> Verdict.NEEDS_ATTENTION
            else -> Verdict.NOTHING_RUNNING
        }

    /** The headline. A number is only used when it is true and useful. */
    fun headline(
        verdict: Verdict,
        running: Int,
    ): String =
        when (verdict) {
            Verdict.NOTHING_INSTALLED -> "Nothing installed yet"
            Verdict.NOTHING_RUNNING -> "Nothing is running"
            Verdict.NEEDS_ATTENTION -> "Something needs attention"
            Verdict.RUNNING -> if (running == 1) "1 tool running" else "$running tools running"
        }

    /** The one action, or null when there is nothing to do — then Home shows no button. */
    fun action(verdict: Verdict): Action? =
        when (verdict) {
            Verdict.NOTHING_INSTALLED -> Action.CHOOSE_TOOL
            Verdict.NEEDS_ATTENTION -> Action.CHOOSE_TOOL
            Verdict.NOTHING_RUNNING -> Action.RESTART_EVERYTHING
            Verdict.RUNNING -> null
        }

    fun actionLabel(action: Action): String =
        when (action) {
            Action.CHOOSE_TOOL -> "Choose a tool"
            Action.RESTART_EVERYTHING -> "Restart everything"
        }

    /** The line under the headline: why that button is the next thing. */
    fun detail(verdict: Verdict): String =
        when (verdict) {
            Verdict.NOTHING_INSTALLED -> "Pick one tool and this app installs it for you."
            Verdict.NOTHING_RUNNING -> "They are installed but not started."
            Verdict.NEEDS_ATTENTION -> "Open Tools to see which one, and why."
            Verdict.RUNNING -> "Everything you installed is up."
        }
}

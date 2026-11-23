package dev.droidai.launcher

/**
 * Turning what a CLI prints into what a person can read.
 *
 * The engine reports each tool's `--version` verbatim, and those strings are written for
 * terminals, not for a card:
 *
 *   n8n        2.48.7                                              <- the good case
 *   openclaw   OpenClaw 2026.9.8 (fc23bc8)                          <- repeats the tool name
 *   hermes     Hermes Agent vgit.707cf0f (2026.9.24) · stable · local 707cf0fde025
 *   ollama     Warning: could not connect to a running Ollama instance
 *
 * The last one is not a version at all, and `vgit.707cf0f` means the checkout has no git
 * tags — it describes our packaging, not the release. This picks the one human-meaningful
 * token out of each, so every tool reads like n8n does.
 */
object Format {
    /** `Hermes Agent vgit.707cf0f (2026.9.24) · stable · …` → `2026.9.24` */
    private val PARENTHESISED_RELEASE = Regex("""\((20\d\d\.\d+\.\d+)\)""")

    /** A dotted number, optionally v-prefixed: `2026.9.8`, `2.48.7`, `v24.22.3`. */
    private val DOTTED = Regex("""^v?\d+(\.\d+)+[0-9A-Za-z.+-]*$""")

    /**
     * A short version string, or "" when the tool did not actually answer.
     *
     * "" is deliberate for warnings and errors: a card that says `Installed` does not need
     * "could not connect to a running Ollama instance" under it, and the raw text is still
     * in Raw Output and in the notification-free log on disk.
     */
    fun toolVersion(raw: String): String {
        val s = raw.trim()
        if (s.isEmpty()) return ""
        val lower = s.lowercase()
        if (lower.startsWith("warning") || lower.startsWith("error")) return ""

        // The release date is the only part of the Hermes banner a person reads.
        PARENTHESISED_RELEASE.find(s)?.let { return it.groupValues[1] }

        val firstLine = s.lineSequence().first().trim()
        // First token that looks like a version. Scanning (not just splitting) keeps
        // "OpenClaw 2026.9.8 (fc23bc8)" and "Python 3.14.10" working with one rule.
        firstLine
            .split(' ', '\t')
            .firstOrNull { DOTTED.matches(it) }
            ?.let { return it.removePrefix("v") }

        // Unknown shape: show it, short, rather than invent something.
        return firstLine.take(32)
    }
}

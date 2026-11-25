package dev.droidai.launcher

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Tool `--version` output is written for a terminal, and the cards need one readable token.
 * These are the real shapes measured on the two test devices (see `AGENTS.md`).
 */
class FormatTest {
    @Test
    fun `hermes banner collapses to its release date`() {
        assertEquals(
            "2026.9.24",
            Format.toolVersion("Hermes Agent vgit.707cf0f (2026.9.24) · stable · local 707cf0fde025"),
        )
    }

    @Test
    fun `a repeated tool name is not part of the version`() {
        assertEquals("2026.9.8", Format.toolVersion("OpenClaw 2026.9.8 (fc23bc8)"))
    }

    @Test
    fun `a plain version is left alone`() {
        assertEquals("2.48.7", Format.toolVersion("2.48.7"))
        assertEquals("24.22.3", Format.toolVersion("v24.22.3"))
    }

    @Test
    fun `a warning is not a version`() {
        // Ollama prints this when nothing is listening; a card saying "Installed" must not
        // carry the sentence underneath it.
        assertEquals("", Format.toolVersion("Warning: could not connect to a running Ollama instance"))
        assertEquals("", Format.toolVersion("Error: not found"))
    }

    @Test
    fun `blank output means no answer`() {
        assertEquals("", Format.toolVersion(""))
        assertEquals("", Format.toolVersion("   \n "))
    }

    @Test
    fun `an unknown shape is shown short rather than invented`() {
        val long = "x".repeat(200)
        assertEquals(32, Format.toolVersion(long).length)
    }

    @Test
    fun `predicate names read as sentences`() {
        assertEquals("PostgreSQL isn't running", Protocol.checkLabel("postgres_running"))
        assertEquals("Not in the Termux repo for this CPU", Protocol.checkLabel("pkg_available:ollama"))
        assertEquals("No Python wheel matches this interpreter", Protocol.checkLabel("has_matching_jiter_wheel"))
    }

    @Test
    fun `a termux version keeps its three-part number and drops the pre-release tail`() {
        // Termux prints the pre-release suffix, and it is the longest thing on the row. The
        // full string is still what a screen reader says and what About shows.
        assertEquals("0.119.0", Format.shortVersion("0.119.0-beta.3"))
        assertEquals("0.119.0", Format.shortVersion("0.119.0"))
    }

    @Test
    fun `a version without three parts is returned unchanged, never truncated`() {
        // Truncating to something that looks like a different version would be worse than a
        // slightly long row.
        assertEquals("0.119", Format.shortVersion("0.119"))
        assertEquals("nightly", Format.shortVersion("nightly"))
        assertEquals("", Format.shortVersion(""))
    }
}

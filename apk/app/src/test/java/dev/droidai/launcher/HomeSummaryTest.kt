package dev.droidai.launcher

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Home is one sentence and one button (F3). Which sentence, and which button, is decided here so
 * it can be checked without a device.
 *
 * The bug this replaces: a phone with nothing installed was told its services were down, and the
 * only button offered was "Restart services" — a command that resurrects services that do not
 * exist. The empty-device case must offer *choosing a tool*, and nothing else.
 */
class HomeSummaryTest {
    @Test
    fun `an empty device is asked to choose a tool, not to restart anything`() {
        val v = HomeSummary.verdict(installed = 0, running = 0, needsAttention = false)
        assertEquals(HomeSummary.Verdict.NOTHING_INSTALLED, v)
        assertEquals("Nothing installed yet", HomeSummary.headline(v, running = 0))
        assertEquals(HomeSummary.Action.CHOOSE_TOOL, HomeSummary.action(v))
        assertEquals("Choose a tool", HomeSummary.actionLabel(HomeSummary.Action.CHOOSE_TOOL))
    }

    @Test
    fun `installed but stopped offers exactly one restart`() {
        val v = HomeSummary.verdict(installed = 2, running = 0, needsAttention = false)
        assertEquals("Nothing is running", HomeSummary.headline(v, running = 0))
        assertEquals(HomeSummary.Action.RESTART_EVERYTHING, HomeSummary.action(v))
        assertEquals("Restart everything", HomeSummary.actionLabel(HomeSummary.Action.RESTART_EVERYTHING))
    }

    @Test
    fun `a running tool needs no button at all`() {
        val v = HomeSummary.verdict(installed = 2, running = 1, needsAttention = false)
        assertEquals("1 tool running", HomeSummary.headline(v, running = 1))
        assertNull(HomeSummary.action(v))
    }

    @Test
    fun `the headline counts tools in the plural`() {
        assertEquals(
            "3 tools running",
            HomeSummary.headline(HomeSummary.Verdict.RUNNING, running = 3),
        )
    }

    @Test
    fun `something online beats every other verdict`() {
        // A device can serve from a package this build does not recognise; reporting "nothing
        // installed" over a live gateway would be the same mistake in the other direction.
        assertEquals(
            HomeSummary.Verdict.RUNNING,
            HomeSummary.verdict(installed = 0, running = 1, needsAttention = true),
        )
    }

    @Test
    fun `a failed tool points at Tools rather than at a restart`() {
        val v = HomeSummary.verdict(installed = 1, running = 0, needsAttention = true)
        assertEquals("Something needs attention", HomeSummary.headline(v, running = 0))
        assertEquals(HomeSummary.Action.CHOOSE_TOOL, HomeSummary.action(v))
    }
}

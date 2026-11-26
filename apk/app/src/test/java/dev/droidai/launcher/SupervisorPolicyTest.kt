package dev.droidai.launcher

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The notification is the app's only always-visible statement, so its verdict is pinned here.
 *
 * The bug these tests exist for: the supervisor starts on first launch, when nothing is
 * installed and no service is expected. It counted `0 online` as a fault, tried to resurrect
 * services that did not exist, and after three attempts told the user "Services are down and
 * restarting did not help" — on a phone that had never installed a tool.
 */
class SupervisorPolicyTest {
    @Test
    fun `a phone with nothing installed is healthy, not down`() {
        assertEquals(
            SupervisorPolicy.Verdict.NOTHING_INSTALLED,
            SupervisorPolicy.classify(running = 0, installedTools = 0, autoStart = true),
        )
    }

    @Test
    fun `auto-start off is only worth reporting when a tool exists`() {
        assertEquals(
            SupervisorPolicy.Verdict.NO_SERVICES_AUTOSTART_OFF,
            SupervisorPolicy.classify(running = 0, installedTools = 1, autoStart = false),
        )
    }

    @Test
    fun `an installed tool with nothing online is the case worth restarting`() {
        assertEquals(
            SupervisorPolicy.Verdict.NO_SERVICES,
            SupervisorPolicy.classify(running = 0, installedTools = 1, autoStart = true),
        )
    }

    @Test
    fun `one online service is healthy even if nothing is recognised as installed`() {
        assertEquals(
            SupervisorPolicy.Verdict.HEALTHY,
            SupervisorPolicy.classify(running = 1, installedTools = 0, autoStart = true),
        )
    }

    @Test
    fun `several online services are healthy`() {
        assertEquals(
            SupervisorPolicy.Verdict.HEALTHY,
            SupervisorPolicy.classify(running = 3, installedTools = 2, autoStart = false),
        )
    }
}

/**
 * Busy is not broken, and a crash loop backs off.
 *
 * Two separate regressions live here, both invisible without a unit test: the launch probe and
 * the supervisor's first check race for one command slot, and the loser's `false` used to mark a
 * healthy phone unhealthy — then the same counter that records failures also decided the retry
 * interval, so a few unlucky races would silently stretch it to 30 minutes.
 */
class SupervisorRetryTest {
    @Test
    fun `a busy transport leaves the verdict and the backoff untouched`() {
        assertEquals(
            3,
            SupervisorPolicy.nextUnhealthyCount(3, CheckResult.BUSY),
        )
    }

    @Test
    fun `a real failure counts`() {
        assertEquals(1, SupervisorPolicy.nextUnhealthyCount(0, CheckResult.UNHEALTHY))
        assertEquals(4, SupervisorPolicy.nextUnhealthyCount(3, CheckResult.UNHEALTHY))
    }

    @Test
    fun `a success resets the backoff immediately`() {
        assertEquals(0, SupervisorPolicy.nextUnhealthyCount(9, CheckResult.HEALTHY))
        assertEquals(SupervisorPolicy.HEALTHY_GAP_MS, SupervisorPolicy.gapMs(0))
    }

    @Test
    fun `the retry interval backs off one, five, fifteen, thirty minutes`() {
        assertEquals(1 * 60_000L, SupervisorPolicy.gapMs(1))
        assertEquals(5 * 60_000L, SupervisorPolicy.gapMs(2))
        assertEquals(15 * 60_000L, SupervisorPolicy.gapMs(3))
        assertEquals(30 * 60_000L, SupervisorPolicy.gapMs(4))
    }

    @Test
    fun `the interval stops growing at thirty minutes`() {
        assertEquals(30 * 60_000L, SupervisorPolicy.gapMs(50))
    }

    @Test
    fun `every unhealthy interval is longer than the healthy one would allow`() {
        // The healthy gap is "at most every five minutes"; a first retry at one minute is
        // deliberately sooner, but nothing in the schedule may be *shorter* than a minute — that
        // is the crash-loop case the old fixed 60 s cadence could not escape.
        assertTrue(SupervisorPolicy.gapMs(1) >= 60_000L)
        assertTrue(SupervisorPolicy.gapMs(4) > SupervisorPolicy.HEALTHY_GAP_MS)
    }
}

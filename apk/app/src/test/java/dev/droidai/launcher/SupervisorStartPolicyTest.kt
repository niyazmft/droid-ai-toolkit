package dev.droidai.launcher

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Q5: the supervisor runs on an empty device, and says something true about it.
 *
 * Two wrong answers existed around this. The first is the old one — announcing "Services are
 * down and restarting did not help" to a phone that never installed anything. The second is the
 * tempting one — staying silent until the first install, which leaves a tool installed from the
 * Termux menu unwatched until the app is next opened.
 *
 * This pins the middle: run always, and treat "nothing installed" as healthy.
 */
class SupervisorStartPolicyTest {
    @Test
    fun `an empty device is never a fault, whatever the auto-start setting is`() {
        // autoStart cannot make an empty device unhealthy: there is nothing to restart.
        assertEquals(
            SupervisorPolicy.Verdict.NOTHING_INSTALLED,
            SupervisorPolicy.classify(running = 0, installedTools = 0, autoStart = true),
        )
        assertEquals(
            SupervisorPolicy.Verdict.NOTHING_INSTALLED,
            SupervisorPolicy.classify(running = 0, installedTools = 0, autoStart = false),
        )
    }

    @Test
    fun `the empty verdict is not on the retry schedule`() {
        // A healthy check resets the backoff; "nothing installed" must report HEALTHY, or an
        // empty phone would sit in the 1 → 5 → 15 → 30 minute retry ladder forever.
        assertEquals(0, SupervisorPolicy.nextUnhealthyCount(4, CheckResult.HEALTHY))
    }
}

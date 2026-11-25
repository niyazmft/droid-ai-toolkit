package dev.droidai.launcher

import org.junit.Assert.assertEquals
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

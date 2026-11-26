package dev.droidai.launcher

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The full status read is the expensive one: it starts a Node/Python runtime per tool to print
 * a version string (10.8 s on y6, 23.1 s on 8x). It belongs on the screen that shows versions,
 * and nowhere else — opening the app, unlocking the phone and finishing a service action must
 * all stay on `--fast`.
 *
 * These cases are what an accidental "just always read fully" would break.
 */
class RefreshPolicyTest {
    @Test
    fun `a process that has never read versions needs a full read`() {
        assertTrue(RefreshPolicy.needsFullRead(now = 1_000_000L, lastFullAt = 0L))
    }

    @Test
    fun `a full read within the window is reused`() {
        val now = 1_000_000L
        assertFalse(RefreshPolicy.needsFullRead(now, lastFullAt = now - 60_000L))
    }

    @Test
    fun `a full read older than the window is repeated`() {
        val now = 1_000_000L
        assertTrue(RefreshPolicy.needsFullRead(now, lastFullAt = now - RefreshPolicy.FULL_REFRESH_MS))
    }

    @Test
    fun `the window is minutes, not seconds`() {
        // A one-second window would make tab switching a slow read each time, which is the
        // behaviour this whole policy exists to avoid.
        assertTrue(RefreshPolicy.FULL_REFRESH_MS >= 60_000L)
    }
}

/** The follow-up read after a finished user action: which form, decided by the action id. */
class PostRunRefreshTest {
    @Test
    fun `a service action refreshes with the fast form`() {
        assertEquals(
            listOf("--api", "status", "--fast"),
            RefreshPolicy.argsAfterRun("service.restart"),
        )
        assertEquals(
            listOf("--api", "status", "--fast"),
            RefreshPolicy.argsAfterRun("service.stop"),
        )
        assertEquals(
            listOf("--api", "status", "--fast"),
            RefreshPolicy.argsAfterRun("service.resurrect"),
        )
    }

    @Test
    fun `an install keeps the full form because the next screen shows a version`() {
        assertEquals(listOf("--api", "status"), RefreshPolicy.argsAfterRun("pi.install"))
        assertEquals(listOf("--api", "status"), RefreshPolicy.argsAfterRun("openclaw.update"))
        assertEquals(listOf("--api", "status"), RefreshPolicy.argsAfterRun("pi.uninstall"))
    }

    @Test
    fun `a read with no action attached is the full form`() {
        assertEquals(listOf("--api", "status"), RefreshPolicy.argsAfterRun(""))
    }

    @Test
    fun `a status read is not a reason to read again`() {
        // The Tools screen sent a full read and then a second one from that read's own
        // completion, so the versions appeared twice a few seconds apart. Only an action can
        // change the device.
        assertFalse(RefreshPolicy.needsPostRunRefresh(""))
        assertTrue(RefreshPolicy.needsPostRunRefresh("service.restart"))
        assertTrue(RefreshPolicy.needsPostRunRefresh("pi.install"))
        assertTrue(RefreshPolicy.needsPostRunRefresh("openclaw.uninstall"))
    }
}

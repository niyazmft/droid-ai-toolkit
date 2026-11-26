package dev.droidai.launcher

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The gate mapping decides which onboarding screen a user sees, so it is worth pinning.
 *
 * Every case here is a real string a device produced. The `NEEDS_PACKAGES` ones come from a
 * clean Termux on Android 16, where the app used to show "Something went wrong / the app reached
 * Termux, but it did not answer as expected" for a missing `jq`.
 */
class GateClassifyTest {
    private fun classify(
        exitCode: Int = 1,
        stdout: String = "",
        stderr: String = "",
        errmsg: String = "",
    ) = Gate.classify(exitCode, stdout, stderr, errmsg)

    @Test
    fun `a status document is ready`() {
        val stdout =
            """{"t":"start","schema":1,"action":"status"}""" + "\n" +
                """{"t":"data","kind":"snapshot","payload":{}}""" + "\n" +
                """{"t":"done","code":0}"""
        assertEquals(Probe.READY, classify(exitCode = 0, stdout = stdout))
    }

    @Test
    fun `the launcher's missing-package error is its own screen`() {
        val stdout =
            """{"t":"error","code":6,"msg":"missing-packages: jq","missing":"jq","hint":"apt install -y jq"}"""
        assertEquals(Probe.NEEDS_PACKAGES, classify(exitCode = 6, stdout = stdout))
    }

    @Test
    fun `the engine's jq refusal is the same screen, not a generic error`() {
        val stdout =
            """{"t":"error","code":3,"msg":"jq is required for the --api interface","missing":"jq","hint":"apt install -y jq"}"""
        assertEquals(Probe.NEEDS_PACKAGES, classify(exitCode = 3, stdout = stdout))
    }

    @Test
    fun `a closed gate is denied, not broken`() {
        assertEquals(
            Probe.DENIED,
            classify(stdout = "termux: allow-external-apps is not enabled"),
        )
    }

    @Test
    fun `a missing checkout is a toolkit problem`() {
        assertEquals(
            Probe.NO_TOOLKIT,
            classify(stdout = """{"t":"error","code":2,"msg":"lib/ not found"}"""),
        )
        assertEquals(Probe.NO_TOOLKIT, classify(errmsg = "first-run setup could not download the toolkit"))
    }

    @Test
    fun `silence means Termux is not running`() {
        assertEquals(Probe.UNREACHABLE, classify(exitCode = -1))
    }

    @Test
    fun `anything else is an error with evidence`() {
        assertEquals(Probe.ERROR, classify(exitCode = 2, stderr = "apt: whatever"))
    }

    @Test
    fun `success wins over text that mentions a missing tool`() {
        // A status run can legitimately mention jq in its output; it is still a successful read.
        val stdout = """{"t":"data","payload":{"checks":{"jq is required for the --api interface":true}}}"""
        assertEquals(Probe.READY, classify(exitCode = 0, stdout = stdout))
    }
}

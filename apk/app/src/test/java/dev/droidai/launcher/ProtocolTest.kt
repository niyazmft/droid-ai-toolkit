package dev.droidai.launcher

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The wire format is the contract (`docs/CONTRACT.md`), so the parser is the one piece of the
 * client that must not be wrong. It also carries the failure classification that turns an exit
 * code into a sentence a person can act on.
 */
class ProtocolTest {
    // NDJSON: one JSON object per line, which is what the engine emits and what the parser
    // consumes. A pretty-printed document is not this format.
    private val status =
        listOf(
            """{"t":"start","action":"status"}""",
            """{"t":"step","id":"collect","title":"Collect device status","state":"running"}""",
            """{"t":"step","id":"collect","title":"Collect device status","state":"ok","ms":1200}""",
            """{"t":"data","payload":{"device":{"model":"TEST-DEVICE","android":"9","api":28,"arch":"armv8l","mem_total_mb":1800,"mem_available_mb":344,"swap_free_mb":120,"disk_free_mb":9216,"hardlinks":false},"termux":{"version":"0.118.0","allow_external_apps":true,"boot_installed":true,"doze_whitelisted":false},"tools":{"node":"22.9.0","pnpm":"9.15.4","python":"3.11.17","openclaw":"","hermes":"","n8n":"2.48.7","ollama":"","pm2_installed":true,"installed":{"openclaw":false,"hermes":false,"n8n":true,"ollama":false}},"services":[{"name":"n8n","status":"online","restarts":0,"mem_mb":210}],"checks":{"postgres_running":false,"pkg_available:ollama":false}}}""",
            """{"t":"end","code":0}""",
        ).joinToString("\n")

    private val catalog =
        listOf(
            """{"schema":1,"actions":[{"id":"hermes.install","title":"Install Hermes","summary":"s","category":"agents","destructive":false,"requires":{"min_mem_mb":384,"min_disk_mb":900,"arch":["aarch64","x86_64"],"predicates":["has_matching_jiter_wheel"]}},{"id":"hermes.uninstall","title":"Remove Hermes","summary":"s","category":"agents","destructive":true}]}""",
        ).joinToString("\n")

    @Test
    fun `status document parses into one snapshot`() {
        val parsed = Protocol.parse(status)
        assertNotNull(parsed.snapshot)
        val snap = requireNotNull(parsed.snapshot)

        assertEquals("TEST-DEVICE", snap.device.model)
        assertEquals(28, snap.device.api)
        assertEquals("armv8l", snap.device.arch)
        assertEquals(344, snap.device.memAvailableMb)
        assertEquals(false, snap.device.hardlinks)
        assertEquals(true, snap.termux.bootInstalled)
        assertEquals("2.48.7", snap.tools.n8n)
        assertEquals(true, snap.tools.pm2Installed)
        assertEquals(true, snap.tools.installed["n8n"])
        assertEquals(false, snap.tools.installed["openclaw"])
        assertEquals(1, snap.services.size)
        assertEquals("online", snap.services[0].status)
        assertEquals(210, snap.services[0].memMb)
        assertEquals(false, snap.checks["postgres_running"])
    }

    @Test
    fun `step transitions collapse to one final state per step`() {
        val steps = Protocol.parse(status).steps
        assertEquals(1, steps.size)
        assertEquals("ok", steps[0].state)
        assertEquals("Collect device status", steps[0].title)
        assertEquals(1200L, steps[0].ms)
    }

    @Test
    fun `catalog parses requires including arch and predicates`() {
        val actions = Protocol.parse(catalog).actions
        assertEquals(2, actions.size)

        val install = actions.first { it.id == "hermes.install" }
        assertEquals(384, install.minMemMb)
        assertEquals(900, install.minDiskMb)
        assertEquals(listOf("aarch64", "x86_64"), install.arch)
        assertEquals(listOf("has_matching_jiter_wheel"), install.predicates)
        assertEquals(false, install.destructive)

        // The uninstall sibling deliberately declares no arch: removing something must work on
        // any cpu. Empty means "no restriction", not "no arches".
        assertEquals(emptyList<String>(), actions.first { it.id == "hermes.uninstall" }.arch)
    }

    @Test
    fun `a status stream is not mistaken for a catalog`() {
        assertTrue(Protocol.parse(status).actions.isEmpty())
        assertNull(Protocol.parse(catalog).snapshot)
    }

    @Test
    fun `an unmet predicate becomes the headline`() {
        val stdout =
            """
            {"t":"log","step":"preflight","line":"preflight refused: unmet: postgres_running"}
            """.trimIndent()
        val failure = Protocol.parse(stdout).failure(3, "", "")
        assertEquals("PostgreSQL isn't running", failure?.headline)
    }

    @Test
    fun `an arch refusal is named as such`() {
        val stdout = """{"t":"log","step":"preflight","line":"refused: arch=armv8l"}"""
        assertEquals("This CPU can't run it", Protocol.parse(stdout).failure(3, "", "")?.headline)
    }

    @Test
    fun `a sigkill exit is attributed to memory, not to the step`() {
        assertEquals(
            "Android killed it — too little memory",
            Protocol.parse("").failure(137, "", "")?.headline,
        )
    }

    @Test
    fun `a failed step carries the tail of its own log as evidence`() {
        val stdout =
            """
            {"t":"step","id":"install","title":"Install package","state":"failed"}
            {"t":"log","step":"install","line":"E: Unable to locate package ollama"}
            {"t":"log","step":"other","line":"unrelated noise"}
            """.trimIndent()
        val failure = Protocol.parse(stdout).failure(1, "", "")
        assertEquals("That step failed: Install package", failure?.headline)
        assertEquals(listOf("E: Unable to locate package ollama"), failure?.details)
    }

    @Test
    fun `the engine's error event wins over the exit code`() {
        val stdout = """{"t":"error","code":4,"msg":"first-run setup could not download the toolkit"}"""
        assertEquals(
            "first-run setup could not download the toolkit",
            Protocol.parse(stdout).failure(4, "", "")?.headline,
        )
    }

    @Test
    fun `colour codes and carriage returns are stripped from evidence`() {
        val stdout =
            """
            {"t":"step","id":"install","title":"Install","state":"failed"}
            {"t":"log","step":"install","line":"\u001b[31mboom\u001b[0m\r"}
            """.trimIndent()
        assertEquals(listOf("boom"), Protocol.parse(stdout).failure(1, "", "")?.details)
    }

    @Test
    fun `non-json lines are dropped rather than guessed at`() {
        val stdout = "not json\n{\"t\":\"end\",\"code\":0}\nalso not json"
        assertEquals(1, Protocol.events(stdout).size)
    }
}

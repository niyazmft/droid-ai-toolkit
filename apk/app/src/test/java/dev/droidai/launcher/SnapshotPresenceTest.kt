package dev.droidai.launcher

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Presence, not versions.
 *
 * The startup probe sends `status --fast`, which blanks every tool version string on purpose
 * (each version probe starts a whole Node/Python runtime: 23.1 s vs ~7 s on 8x). Anything that
 * reads a blank version as "not installed" then reports a working phone as empty — which is
 * exactly how 8x came to say "0 of 8 installed" with four tools on disk, and how the Overview
 * would have lost its "Restart services" button after this change.
 *
 * These tests pin the two shapes the app has to support: the current payload, which carries
 * `tools.installed`, and an older engine's payload, which does not.
 */
class SnapshotPresenceTest {
    private fun payload(
        // A JSON literal, already quoted: `--fast` sends `""` for every version, and an
        // absent value would build `"pnpm":,` — invalid JSON, which is a broken test rather
        // than a broken app.
        versions: String = "\"\"",
        installed: String? = null,
    ): String {
        val tools =
            buildString {
                append("\"node\":\"v24.0.0\",\"pnpm\":$versions,\"python\":\"\",\"pm2_installed\":true,")
                append("\"openclaw\":$versions,\"hermes\":$versions,\"n8n\":$versions,\"ollama\":$versions")
                if (installed != null) append(",\"installed\":$installed")
            }
        // One line, always: the stream is NDJSON, and a multi-line document is exactly what
        // Protocol.events drops.
        return """{"t":"data","kind":"snapshot","payload":{""" +
            """"device":{"model":"x","android":"10","api":29,"abi":"arm64-v8a","arch":"aarch64",""" +
            """"mem_total_mb":1,"mem_available_mb":1,"swap_total_mb":0,"swap_free_mb":0,""" +
            """"disk_free_mb":1,"hardlinks":true},""" +
            """"termux":{"version":"0.119.0","allow_external_apps":true,"boot_installed":false,""" +
            """"doze_whitelisted":false},""" +
            """"tools":{$tools},""" +
            """"services":[],"checks":{}}}"""
    }

    private fun snapshot(
        versions: String = "\"\"",
        installed: String? = null,
    ): Protocol.Snapshot =
        Protocol.parse(payload(versions, installed)).snapshot
            ?: error("the payload must parse")

    @Test
    fun `a fast snapshot keeps installed tools from the engine's flags`() {
        val snap = snapshot(installed = """{"openclaw":true,"hermes":false,"n8n":true,"ollama":false}""")
        assertEquals(setOf("openclaw", "n8n"), snap.installedKeys())
        assertTrue(snap.isInstalled("openclaw"))
        assertFalse("a false flag must beat a blank version", snap.isInstalled("hermes"))
    }

    @Test
    fun `a fast snapshot never reports versions`() {
        val snap = snapshot(installed = """{"openclaw":true}""")
        assertEquals("", snap.versionOf("openclaw"))
    }

    @Test
    fun `an engine without tools installed falls back to non-blank versions`() {
        val snap = snapshot(versions = "\"2026.9.3\"")
        assertEquals(setOf("openclaw", "hermes", "n8n", "ollama"), snap.installedKeys())
        assertTrue(snap.isInstalled("n8n"))
    }

    @Test
    fun `a tool the payload cannot probe is not silently installed`() {
        val snap = snapshot(versions = "\"2026.9.3\"")
        assertEquals("", snap.versionOf("gemini"))
        assertFalse(snap.isInstalled("gemini"))
    }

    @Test
    fun `one installed tool the engine knows about survives a fast refresh`() {
        // The supervisor polls --fast on every unlock; before this rule its snapshot replaced
        // the Overview's fuller one and the app believed nothing was installed any more.
        val snap = snapshot(installed = """{"ollama":true}""")
        assertTrue(snap.isInstalled("ollama"))
        assertEquals(setOf("ollama"), snap.installedKeys())
    }
}

/**
 * A `--fast` snapshot may refresh the cheap half of the screen, never delete the expensive half.
 *
 * The startup probe now sends `--fast` (23.1 s → ~7 s on 8x), and the supervisor always did.
 * Before this merge a fast read replaced the full one, so the Overview lost its tool versions
 * and Packages lost its installed count the moment either ran — a visible regression with a
 * server-side cause that is very hard to connect back to a polling interval.
 */
class SnapshotMergeTest {
    private fun payload(
        version: String,
        memFree: Int,
        installed: String = """{"openclaw":true}""",
    ): String =
        """{"t":"data","kind":"snapshot","payload":{""" +
            """"device":{"model":"x","android":"10","api":29,"abi":"arm64-v8a","arch":"aarch64",""" +
            """"mem_total_mb":1000,"mem_available_mb":$memFree,"swap_total_mb":0,"swap_free_mb":0,""" +
            """"disk_free_mb":1,"hardlinks":true},""" +
            """"termux":{"version":"0.119.0","allow_external_apps":true,"boot_installed":false,""" +
            """"doze_whitelisted":false},""" +
            """"tools":{"node":"v24.0.0","pnpm":"","python":"","pm2_installed":true,""" +
            """"openclaw":$version,"hermes":"","n8n":"","ollama":"","installed":$installed},""" +
            """"services":[],"checks":{}}}"""

    private fun parse(payload: String) = Protocol.parse(payload).snapshot ?: error("must parse")

    @Test
    fun `a fast snapshot keeps the versions the last full read found`() {
        val full = parse(payload(version = "\"OpenClaw 2026.9.3\"", memFree = 300))
        val fast = parse(payload(version = "\"\"", memFree = 500))

        val merged = fast.mergedWith(full)
        assertEquals("OpenClaw 2026.9.3", merged.tools.openclaw)
        assertEquals(500, merged.device.memAvailableMb)
    }

    @Test
    fun `a fast snapshot keeps the installed flags when it carries none`() {
        val full = parse(payload(version = "\"v1\"", memFree = 1, installed = """{"openclaw":true,"n8n":true}"""))
        val noFlags = parse(payload(version = "\"\"", memFree = 2, installed = """{}"""))
        assertEquals(setOf("openclaw", "n8n"), noFlags.mergedWith(full).installedKeys())
    }

    @Test
    fun `merging with nothing to merge into is the snapshot itself`() {
        val fast = parse(payload(version = "\"\"", memFree = 5))
        assertEquals(fast, fast.mergedWith(null))
    }

    @Test
    fun `a full snapshot needs no merge`() {
        val full = parse(payload(version = "\"v1\"", memFree = 1))
        val newer = parse(payload(version = "\"v2\"", memFree = 2))
        assertEquals("v2", newer.mergedWith(full).tools.openclaw)
    }
}

/**
 * The legacy-folder facts (F7).
 *
 * The Cleanup panel exists only when the pre-migration shared folder is still there, and its
 * button is disabled while a tool still runs from it. Without these fields the app could only
 * always offer the button, and on 8x that button removed nothing and reported "done" — the same
 * message as a successful 12.9 GB cleanup.
 */
class LegacyGlobalTest {
    private fun parse(termux: String): Protocol.Snapshot =
        Protocol
            .parse(
                """{"t":"data","kind":"snapshot","payload":{""" +
                    """"device":{"model":"x","android":"10","api":29,"abi":"a","arch":"aarch64",""" +
                    """"mem_total_mb":1,"mem_available_mb":1,"swap_total_mb":0,"swap_free_mb":0,""" +
                    """"disk_free_mb":1,"hardlinks":true},""" +
                    """"termux":$termux,""" +
                    """"tools":{"node":"","pnpm":"","python":"","pm2_installed":false,""" +
                    """"openclaw":"","hermes":"","n8n":"","ollama":""},""" +
                    """"services":[],"checks":{}}}""",
            ).snapshot ?: error("must parse")

    @Test
    fun `a migrated device has no legacy folder`() {
        val snap =
            parse(
                """{"version":"0.119.0","allow_external_apps":true,"boot_installed":true,"doze_whitelisted":false,"legacy_global":{"present":false,"mb":0}}""",
            )
        assertEquals(false, snap.termux.legacyGlobalPresent)
        assertEquals(0, snap.termux.legacyGlobalMb)
    }

    @Test
    fun `a device with the old tree reports its size in MB`() {
        val snap =
            parse(
                """{"version":"0.119.0","allow_external_apps":true,"boot_installed":true,"doze_whitelisted":false,"legacy_global":{"present":true,"mb":13200}}""",
            )
        assertEquals(true, snap.termux.legacyGlobalPresent)
        assertEquals(13200, snap.termux.legacyGlobalMb)
    }

    @Test
    fun `an engine without the field reads as absent, not as zero bytes present`() {
        val snap =
            parse("""{"version":"0.119.0","allow_external_apps":true,"boot_installed":true,"doze_whitelisted":false}""")
        assertEquals(false, snap.termux.legacyGlobalPresent)
    }

    @Test
    fun `the reclaimed payload is read when the cleanup reports it`() {
        val stdout =
            """{"t":"data","kind":"cleanup","payload":{"reclaimed_mb":13200,"shims":812}}"""
        assertEquals(13200 to 812, Protocol.parse(stdout).reclaimed)
    }

    @Test
    fun `a run with no cleanup payload reports nothing reclaimed`() {
        assertEquals(null, Protocol.parse("""{"t":"data","kind":"snapshot","payload":{}}""").reclaimed)
    }
}

package dev.droidai.launcher

import org.json.JSONObject

/**
 * Reads the NDJSON the toolkit emits in `--api` mode.
 *
 * The wire format stays JSON on purpose — it is the contract, and it is what
 * makes a new tool appear in the app without an APK release. The app's job is to
 * turn it into screens, not to show it to the user. Raw output is still available
 * behind a toggle, because when something fails the raw stream is the evidence.
 */
object Protocol {

    data class Device(
        val model: String,
        val android: String,
        val api: Int,
        val arch: String,
        val memTotalMb: Int,
        val memAvailableMb: Int,
        val swapFreeMb: Int,
        val diskFreeMb: Int,
        val hardlinks: Boolean
    )

    data class TermuxInfo(
        val version: String,
        val allowExternalApps: Boolean,
        val bootInstalled: Boolean,
        val dozeWhitelisted: Boolean
    )

    data class Tools(
        val node: String,
        val pnpm: String,
        val python: String,
        val openclaw: String,
        val hermes: String,
        val n8n: String,
        val ollama: String,
        val pm2Installed: Boolean
    )

    data class Service(val name: String, val status: String, val restarts: Int, val memMb: Int)

    data class Snapshot(
        val device: Device,
        val termux: TermuxInfo,
        val tools: Tools,
        val services: List<Service>
    )

    data class Action(
        val id: String,
        val title: String,
        val summary: String,
        val category: String,
        val destructive: Boolean
    )

    /** Every JSON line in the stream, in order. Non-JSON lines are dropped. */
    fun events(stdout: String): List<JSONObject> =
        stdout.lineSequence().mapNotNull { line ->
            val trimmed = line.trim()
            if (!trimmed.startsWith("{")) return@mapNotNull null
            runCatching { JSONObject(trimmed) }.getOrNull()
        }.toList()

    /** The `data` payload of a status run, if present. */
    fun snapshot(stdout: String): Snapshot? {
        val payload = events(stdout).firstOrNull { it.optString("t") == "data" }
            ?.optJSONObject("payload") ?: return null
        return runCatching {
            val d = payload.getJSONObject("device")
            val t = payload.getJSONObject("termux")
            val tool = payload.getJSONObject("tools")
            val services = payload.optJSONArray("services") ?: return@runCatching null
            Snapshot(
                device = Device(
                    model = d.optString("model"),
                    android = d.optString("android"),
                    api = d.optInt("api"),
                    arch = d.optString("arch"),
                    memTotalMb = d.optInt("mem_total_mb"),
                    memAvailableMb = d.optInt("mem_available_mb"),
                    swapFreeMb = d.optInt("swap_free_mb"),
                    diskFreeMb = d.optInt("disk_free_mb"),
                    hardlinks = d.optBoolean("hardlinks")
                ),
                termux = TermuxInfo(
                    version = t.optString("version"),
                    allowExternalApps = t.optBoolean("allow_external_apps"),
                    bootInstalled = t.optBoolean("boot_installed"),
                    dozeWhitelisted = t.optBoolean("doze_whitelisted")
                ),
                tools = Tools(
                    node = tool.optString("node"),
                    pnpm = tool.optString("pnpm"),
                    python = tool.optString("python"),
                    openclaw = tool.optString("openclaw"),
                    hermes = tool.optString("hermes"),
                    n8n = tool.optString("n8n"),
                    ollama = tool.optString("ollama"),
                    pm2Installed = tool.optBoolean("pm2_installed")
                ),
                services = (0 until services.length()).map { i ->
                    val s = services.getJSONObject(i)
                    Service(
                        name = s.optString("name"),
                        status = s.optString("status"),
                        restarts = s.optInt("restarts"),
                        memMb = s.optInt("mem_mb")
                    )
                }
            )
        }.getOrNull()
    }

    /** The action catalog (`--api list`). */
    fun actions(stdout: String): List<Action> {
        val doc = events(stdout).firstOrNull { it.optJSONArray("actions") != null }
            ?: events(stdout).firstOrNull { it.optString("t") == "data" && it.optJSONObject("payload")?.optJSONArray("actions") != null }
            ?: return emptyList()
        val array = doc.optJSONArray("actions")
            ?: doc.optJSONObject("payload")?.optJSONArray("actions")
            ?: return emptyList()
        return (0 until array.length()).mapNotNull { i ->
            val a = array.optJSONObject(i) ?: return@mapNotNull null
            Action(
                id = a.optString("id"),
                title = a.optString("title"),
                summary = a.optString("summary"),
                category = a.optString("category"),
                destructive = a.optBoolean("destructive")
            )
        }
    }

    data class Step(val title: String, val state: String, val ms: Long)

    /**
     * Every `step` event, in order. A background RUN_COMMAND only returns at the end,
     * so this is the post-run record rather than a live feed — but "which step
     * failed" is the question a user actually asks, and prose logs do not answer it.
     */
    fun steps(stdout: String): List<Step> =
        events(stdout).filter { it.optString("t") == "step" }.mapNotNull { e ->
            val title = e.optString("title").ifBlank { e.optString("id") }
            if (title.isBlank()) null
            else Step(title = title, state = e.optString("state"), ms = e.optLong("ms"))
        }

    /** The last `step` event's title, for a progress line. */
    fun currentStep(stdout: String): String? =
        events(stdout).lastOrNull { it.optString("t") == "step" }
            ?.takeIf { it.optString("state") == "running" }
            ?.optString("title")

    /** A human-readable failure from the stream or the Termux-level error. */
    fun error(stdout: String, stderr: String, errmsg: String): String? {
        if (errmsg.isNotBlank()) return errmsg
        val fromStream = events(stdout).firstOrNull { it.optString("t") == "error" }
            ?.optString("msg")
        if (!fromStream.isNullOrBlank()) return fromStream
        val failedStep = events(stdout).lastOrNull { it.optString("t") == "step" && it.optString("state") == "failed" }
        if (failedStep != null) return "Step failed: ${failedStep.optString("title")}"
        return stderr.takeIf { it.isNotBlank() }
    }
}

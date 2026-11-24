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
        val hardlinks: Boolean,
    )

    data class TermuxInfo(
        val version: String,
        val allowExternalApps: Boolean,
        val bootInstalled: Boolean,
        val dozeWhitelisted: Boolean,
    )

    data class Tools(
        val node: String,
        val pnpm: String,
        val python: String,
        val openclaw: String,
        val hermes: String,
        val n8n: String,
        val ollama: String,
        val pm2Installed: Boolean,
        /**
         * Presence per catalog tool, decided by the engine from the filesystem, not from a
         * version string. Empty when the engine is older than this field — callers must
         * fall back to [openclaw]/[hermes]/… being non-blank.
         */
        val installed: Map<String, Boolean> = emptyMap(),
    )

    data class Service(
        val name: String,
        val status: String,
        val restarts: Int,
        val memMb: Int,
    )

    data class Snapshot(
        val device: Device,
        val termux: TermuxInfo,
        val tools: Tools,
        val services: List<Service>,
        /**
         * Preconditions the catalog names (`postgres_running`, `pkg_available:ollama`, …)
         * and whether the engine found them satisfied right now.
         *
         * These are not advisory: the engine refuses to run the action when one is
         * unmet, and `--force` does not override them. Showing them up front is the
         * difference between a disabled button with a reason and a bare exit 3.
         */
        val checks: Map<String, Boolean> = emptyMap(),
    )

    data class Action(
        val id: String,
        val title: String,
        val summary: String,
        val category: String,
        val destructive: Boolean,
        val minMemMb: Int,
        val minDiskMb: Int,
        /** Arches this action can run on; empty means "no restriction declared". */
        val arch: List<String>,
        /** Named preconditions (`postgres_running`, `pkg_available:ollama`, …). */
        val predicates: List<String> = emptyList(),
    )

    /**
     * One parse of one stream, with every view derived from the same event list.
     *
     * The client used to re-parse the same stdout up to five times per result — snapshot,
     * the catalogue twice, the step list twice, the failure — on the main thread, for a
     * string that reaches hundreds of KB after a long install. [events] is now the only
     * pass; everything else is a view computed once.
     */
    class Parsed internal constructor(
        val events: List<JSONObject>,
    ) {
        /** The `data` payload of a status run, if present. */
        val snapshot: Snapshot? by lazy { snapshotOf(events) }

        /** The action catalog (`--api list`), or empty when the stream carries none. */
        val actions: List<Action> by lazy { actionsOf(events) }

        /** One entry per step, in first-seen order, showing its final state. */
        val steps: List<Step> by lazy { finalStepsOf(events) }

        /** A failure in two parts: a sentence to act on, and the evidence. */
        fun failure(
            exitCode: Int,
            stderr: String,
            errmsg: String,
        ): Failure? = failureOf(exitCode, events, stderr, errmsg)
    }

    fun parse(stdout: String): Parsed = Parsed(events(stdout))

    /** Every JSON line in the stream, in order. Non-JSON lines are dropped. */
    fun events(stdout: String): List<JSONObject> =
        stdout
            .lineSequence()
            .mapNotNull { line ->
                val trimmed = line.trim()
                if (!trimmed.startsWith("{")) return@mapNotNull null
                runCatching { JSONObject(trimmed) }.getOrNull()
            }.toList()

    /** The `data` payload of a status run, if present. */
    fun snapshot(stdout: String): Snapshot? = snapshotOf(events(stdout))

    private fun snapshotOf(evs: List<JSONObject>): Snapshot? {
        val payload =
            evs
                .firstOrNull { it.optString("t") == "data" }
                ?.optJSONObject("payload") ?: return null
        return runCatching {
            val d = payload.getJSONObject("device")
            val t = payload.getJSONObject("termux")
            val tool = payload.getJSONObject("tools")
            val services = payload.optJSONArray("services") ?: return@runCatching null
            Snapshot(
                device =
                    Device(
                        model = d.optString("model"),
                        android = d.optString("android"),
                        api = d.optInt("api"),
                        arch = d.optString("arch"),
                        memTotalMb = d.optInt("mem_total_mb"),
                        memAvailableMb = d.optInt("mem_available_mb"),
                        swapFreeMb = d.optInt("swap_free_mb"),
                        diskFreeMb = d.optInt("disk_free_mb"),
                        hardlinks = d.optBoolean("hardlinks"),
                    ),
                termux =
                    TermuxInfo(
                        version = t.optString("version"),
                        allowExternalApps = t.optBoolean("allow_external_apps"),
                        bootInstalled = t.optBoolean("boot_installed"),
                        dozeWhitelisted = t.optBoolean("doze_whitelisted"),
                    ),
                tools =
                    Tools(
                        node = tool.optString("node"),
                        pnpm = tool.optString("pnpm"),
                        python = tool.optString("python"),
                        openclaw = tool.optString("openclaw"),
                        hermes = tool.optString("hermes"),
                        n8n = tool.optString("n8n"),
                        ollama = tool.optString("ollama"),
                        pm2Installed = tool.optBoolean("pm2_installed"),
                        installed =
                            tool.optJSONObject("installed")?.let { obj ->
                                obj
                                    .keys()
                                    .asSequence()
                                    .associateWith { k -> obj.optBoolean(k) }
                            } ?: emptyMap(),
                    ),
                checks =
                    payload.optJSONObject("checks")?.let { obj ->
                        obj.keys().asSequence().associateWith { k -> obj.optBoolean(k) }
                    } ?: emptyMap(),
                services =
                    (0 until services.length()).map { i ->
                        val s = services.getJSONObject(i)
                        Service(
                            name = s.optString("name"),
                            status = s.optString("status"),
                            restarts = s.optInt("restarts"),
                            memMb = s.optInt("mem_mb"),
                        )
                    },
            )
        }.getOrNull()
    }

    /** The action catalog (`--api list`). */
    fun actions(stdout: String): List<Action> = actionsOf(events(stdout))

    private fun actionsOf(evs: List<JSONObject>): List<Action> {
        val doc =
            evs.firstOrNull { it.optJSONArray("actions") != null }
                ?: evs.firstOrNull {
                    it.optString("t") == "data" &&
                        it.optJSONObject("payload")?.optJSONArray("actions") != null
                }
                ?: return emptyList()
        val array =
            doc.optJSONArray("actions")
                ?: doc.optJSONObject("payload")?.optJSONArray("actions")
                ?: return emptyList()
        return (0 until array.length()).mapNotNull { i ->
            val a = array.optJSONObject(i) ?: return@mapNotNull null
            Action(
                id = a.optString("id"),
                title = a.optString("title"),
                summary = a.optString("summary"),
                category = a.optString("category"),
                destructive = a.optBoolean("destructive"),
                minMemMb = a.optJSONObject("requires")?.optInt("min_mem_mb") ?: 0,
                minDiskMb = a.optJSONObject("requires")?.optInt("min_disk_mb") ?: 0,
                arch = archList(a.optJSONObject("requires")),
                predicates = stringList(a.optJSONObject("requires"), "predicates"),
            )
        }
    }

    /**
     * `requires.arch`, or an empty list when the spec declares no restriction.
     *
     * The catalog has always carried this; the app ignored it, so a 32-bit device was
     * offered Install for tools that only ship aarch64 builds and got a bare exit 3.
     */
    private fun archList(requires: JSONObject?): List<String> = stringList(requires, "arch")

    /** A string array under `requires`, e.g. `arch` or `predicates`. */
    private fun stringList(
        requires: JSONObject?,
        key: String,
    ): List<String> {
        val arr = requires?.optJSONArray(key) ?: return emptyList()
        return (0 until arr.length()).map { arr.optString(it) }.filter { it.isNotBlank() }
    }

    data class Step(
        val id: String,
        val title: String,
        val state: String,
        val ms: Long,
    )

    /**
     * Every `step` event, in order. A background RUN_COMMAND only returns at the end,
     * so this is the post-run record rather than a live feed — but "which step
     * failed" is the question a user actually asks, and prose logs do not answer it.
     */
    fun steps(stdout: String): List<Step> = stepsOf(events(stdout))

    private fun stepsOf(evs: List<JSONObject>): List<Step> =
        evs.filter { it.optString("t") == "step" }.mapNotNull { e ->
            val title = e.optString("title").ifBlank { e.optString("id") }
            if (title.isBlank()) {
                null
            } else {
                Step(
                    id = e.optString("id"),
                    title = title,
                    state = e.optString("state"),
                    ms = e.optLong("ms"),
                )
            }
        }

    /**
     * One entry per step, in first-seen order, showing its final state.
     *
     * The stream emits `running` and then `ok` for the same step, so the raw list shows
     * every step twice. What a reader wants is the outcome, not the transitions.
     */
    fun finalSteps(stdout: String): List<Step> = finalStepsOf(events(stdout))

    private fun finalStepsOf(evs: List<JSONObject>): List<Step> {
        val order = LinkedHashMap<String, Step>()
        stepsOf(evs).forEach { step ->
            val key = step.id.ifBlank { step.title }
            val previous = order[key]
            // A terminal state wins; a later `running` must not overwrite it.
            if (previous == null || previous.state == "running" || step.state != "running") {
                order[key] = step
            }
        }
        return order.values.toList()
    }

    /** The last `step` event's title, for a progress line. */
    fun currentStep(stdout: String): String? =
        events(stdout)
            .lastOrNull { it.optString("t") == "step" }
            ?.takeIf { it.optString("state") == "running" }
            ?.optString("title")

    /**
     * A failure in two parts: one sentence a person can act on, and the evidence.
     *
     * The banner used to read "Step failed: Install package" — the title of the step, not
     * the reason. The engine now replays the tail of a failed step's log as `log` events
     * (see CONTRACT.md), which is the only way the app can see it: Termux's home is
     * app-private, so the log file on disk is unreadable from here.
     */
    data class Failure(
        val headline: String,
        val details: List<String> = emptyList(),
    )

    /** Phrases for the preconditions the catalog can name, in the app's voice. */
    fun checkLabel(key: String): String =
        when {
            key == "postgres_running" -> "PostgreSQL isn't running"
            key == "has_matching_jiter_wheel" -> "No Python wheel matches this interpreter"
            key == "has_warm_pnpm_store" -> "No warm package cache yet"
            key.startsWith("pkg_available:") -> "Not in the Termux repo for this CPU"
            else -> "A requirement isn't met ($key)"
        }

    fun failure(
        exitCode: Int,
        stdout: String,
        stderr: String,
        errmsg: String,
    ): Failure? = failureOf(exitCode, events(stdout), stderr, errmsg)

    private fun failureOf(
        exitCode: Int,
        evs: List<JSONObject>,
        stderr: String,
        errmsg: String,
    ): Failure? {
        if (errmsg.isNotBlank()) return Failure(errmsg)
        evs
            .firstOrNull { it.optString("t") == "error" }
            ?.optString("msg")
            ?.takeIf { it.isNotBlank() }
            ?.let { return Failure(it) }

        val failed = evs.lastOrNull { it.optString("t") == "step" && it.optString("state") == "failed" }
        val stepId = failed?.optString("id").orEmpty()
        val stepTitle = failed?.optString("title").orEmpty()

        val stepTail =
            evs
                .filter { it.optString("t") == "log" }
                .filter { stepId.isNotBlank() && it.optString("step") == stepId }
                .map { clean(it.optString("line")) }
                .filter { it.isNotBlank() }
                .takeLast(12)

        val refused =
            evs
                .filter { it.optString("t") == "log" && it.optString("step") == "preflight" }
                .map { clean(it.optString("line")) }
                .lastOrNull()
                .orEmpty()

        val unmet = unmetPredicates(refused)

        val headline =
            when {
                exitCode == 3 && unmet.isNotEmpty() -> unmet.map { checkLabel(it) }.first()
                exitCode == 3 && refused.contains("arch=") -> "This CPU can't run it"
                exitCode == 3 && refused.contains("mem=") -> "Not enough memory right now"
                exitCode == 3 && refused.contains("disk=") -> "Not enough storage right now"
                exitCode == 3 -> "This device is missing something it needs"
                exitCode == 4 -> "Cancelled — it needs confirmation first"
                exitCode == 5 -> "A question went unanswered"
                exitCode == 137 -> "Android killed it — too little memory"
                exitCode == 1 && stepTitle.isNotBlank() -> "That step failed: $stepTitle"
                exitCode == 1 -> "A step failed"
                exitCode != 0 -> "Failed (exit $exitCode)"
                stderr.isNotBlank() -> clean(stderr).lineSequence().firstOrNull { it.isNotBlank() } ?: "Failed"
                else -> null
            } ?: return null

        val details =
            buildList {
                addAll(stepTail)
                if (stepTail.isEmpty() && refused.isNotBlank()) add(refused)
            }
        return Failure(headline, details)
    }

    /** Predicate names the engine reported as unmet, from its preflight refusal line. */
    private fun unmetPredicates(refused: String): List<String> {
        val marker = "unmet:"
        val at = refused.indexOf(marker)
        if (at < 0) return emptyList()
        return refused
            .substring(at + marker.length)
            .trim()
            .split(" ")
            .filter { it.isNotBlank() }
    }

    /** Strip colour codes and control characters the engine's tools like to emit. */
    private fun clean(line: String): String = line.replace(RE_ANSI, "").replace("\r", "").trim()

    private val RE_ANSI = Regex("\u001B\\[[0-9;]*[A-Za-z]")
}

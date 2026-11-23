package dev.droidai.launcher

import android.content.Context
import org.json.JSONObject
import java.io.File

/**
 * A tiny time series, kept on disk so the trend survives the process being killed (which
 * is the exact event the app exists to observe).
 *
 * One JSON line per sample, pruned at seven days. No database: at one sample every five
 * minutes that is 2 016 lines a week, around 60 KB, and a database would cost more in
 * dependencies and startup than the data is worth.
 */
object Metrics {
    private const val FILE = "metrics.jsonl"
    private const val KEEP_MS = 7L * 24 * 60 * 60 * 1000
    private const val PRUNE_ABOVE_BYTES = 256 * 1024

    const val SAMPLE_INTERVAL_MS = 5L * 60 * 1000

    data class Sample(
        val ts: Long,
        val memMb: Int,
        val swapMb: Int,
        val services: Int,
        val rssMb: Int,
    )

    private fun file(context: Context): File = File(context.filesDir, FILE)

    @Synchronized
    fun record(
        context: Context,
        sample: Sample,
    ) {
        runCatching {
            val f = file(context)
            f.appendText(
                JSONObject()
                    .put("ts", sample.ts)
                    .put("mem", sample.memMb)
                    .put("swap", sample.swapMb)
                    .put("svc", sample.services)
                    .put("rss", sample.rssMb)
                    .toString() + "\n",
            )
            if (f.length() > PRUNE_ABOVE_BYTES) prune(f)
        }
    }

    @Synchronized
    fun load(
        context: Context,
        windowMs: Long,
    ): List<Sample> {
        val f = file(context)
        if (!f.exists()) return emptyList()
        val since = System.currentTimeMillis() - windowMs
        return runCatching {
            f.readLines().mapNotNull { line ->
                if (line.isBlank()) return@mapNotNull null
                val o = runCatching { JSONObject(line) }.getOrNull() ?: return@mapNotNull null
                val ts = o.optLong("ts")
                if (ts < since) return@mapNotNull null
                Sample(
                    ts = ts,
                    memMb = o.optInt("mem"),
                    swapMb = o.optInt("swap"),
                    services = o.optInt("svc"),
                    rssMb = o.optInt("rss"),
                )
            }
        }.getOrDefault(emptyList())
    }

    private fun prune(f: File) {
        runCatching {
            val cutoff = System.currentTimeMillis() - KEEP_MS
            val kept =
                f.readLines().filter { line ->
                    val ts = runCatching { JSONObject(line).optLong("ts") }.getOrDefault(0L)
                    ts >= cutoff
                }
            f.writeText(kept.joinToString("\n", postfix = if (kept.isEmpty()) "" else "\n"))
        }
    }
}

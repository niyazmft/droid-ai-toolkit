package dev.droidai.launcher

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Environment
import androidx.core.content.ContextCompat
import org.json.JSONObject
import java.io.File

/**
 * Live progress of the run in flight, read from shared storage.
 *
 * A background RUN_COMMAND reports only at the end, so during a 20–40 minute install the app
 * could say nothing but "Working… 12m 40s". The engine now appends one line per step
 * transition to `~/storage/shared/droid-ai/progress.ndjson` (lib/progress.sh); this reads the
 * last line and turns it into "Step 3 of 7 · Install Pi".
 *
 * ## It is optional by construction
 *
 * Shared storage needs `termux-setup-storage` in Termux, which the app cannot do and which no
 * existing install has. So every path here degrades to `null` — no file, no permission, no
 * line — and the banner keeps its elapsed-time form. A progress feature that could break an
 * install by throwing would be worse than no progress.
 */
object Progress {
    /** One line of the feed. */
    data class Step(
        val title: String,
        val index: Int,
        val total: Int,
        val state: String,
        val action: String,
        val at: Long,
    )

    /**
     * Where Termux writes it.
     *
     * `Environment.getExternalStorageDirectory()` is deprecated but correct here: this is the
     * *other app's* shared folder, not ours, and `getExternalFilesDir` would point at a
     * directory Termux cannot write to without a permission that no longer exists on 11+.
     */
    private fun file(): File = File(Environment.getExternalStorageDirectory(), "droid-ai/progress.ndjson")

    fun canRead(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.READ_EXTERNAL_STORAGE) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * The newest step, or null when there is nothing to show.
     *
     * [maxAgeMs] guards against a stale feed: a run that was killed by Android never writes its
     * final line, and showing yesterday's last step as current would be worse than silence.
     */
    fun latest(
        context: Context,
        maxAgeMs: Long = 15 * 60_000L,
    ): Step? {
        if (!canRead(context)) return null
        val f = file()
        if (!f.isFile || !f.canRead()) return null
        val line =
            runCatching {
                f.useLines { lines -> lines.lastOrNull { it.trimStart().startsWith("{") } }
            }.getOrNull() ?: return null
        return parse(line)?.takeIf { it.at == 0L || System.currentTimeMillis() - it.at <= maxAgeMs }
    }

    /** Parse one feed line. Unknown or malformed lines are simply "nothing to show". */
    fun parse(line: String): Step? =
        runCatching {
            val o = JSONObject(line)
            Step(
                title = o.optString("title"),
                index = o.optInt("index"),
                total = o.optInt("total"),
                state = o.optString("state"),
                action = o.optString("action"),
                at = o.optLong("ts"),
            )
        }.getOrNull()

    /** "Step 3 of 7 · Install Pi", or just the title when the total is unknown. */
    fun label(step: Step): String =
        when {
            step.title.isBlank() -> ""
            step.total > 0 && step.index > 0 -> "Step ${step.index} of ${step.total} · ${step.title}"
            else -> step.title
        }
}

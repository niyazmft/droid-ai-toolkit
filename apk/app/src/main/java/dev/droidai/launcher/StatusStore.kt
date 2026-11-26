package dev.droidai.launcher

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * The last status document, kept as a file rather than as a preference.
 *
 * It used to live in `SharedPreferences`. That file is one XML document read **whole** on the
 * first access — which happens in `MainActivity.onCreate` and in `SupervisorService.onCreate`
 * — so every launch parsed a multi-KB JSON blob just to answer "what did the device look like
 * last time?". `SharedPreferences` is for flags (D14); a document belongs in a file, read on
 * [Dispatchers.IO].
 *
 * The timestamp stays in `Prefs`, because `onResume` needs it synchronously to decide whether
 * a refresh is due, and a `Long` is exactly what a preference is for.
 */
object StatusStore {
    private const val FILE = "last_status.ndjson"

    /** A status document larger than this is not worth keeping: it is a snapshot, not a log. */
    private const val MAX_CHARS = 256 * 1024

    private fun file(context: Context): File = File(context.filesDir, FILE)

    /**
     * The previous answer, or "" when there is none.
     *
     * Never throws: a missing, truncated or unreadable file means "nothing to show yet",
     * which the screens already handle by saying they are reading the device.
     */
    suspend fun load(context: Context): String =
        withContext(Dispatchers.IO) {
            runCatching {
                val f = file(context)
                if (f.exists()) f.readText() else ""
            }.getOrDefault("")
        }

    suspend fun save(
        context: Context,
        stdout: String,
    ) {
        if (stdout.isBlank() || stdout.length > MAX_CHARS) return
        withContext(Dispatchers.IO) {
            runCatching { file(context).writeText(stdout) }
        }
    }
}

package dev.droidai.launcher

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.max

private const val HOUR_MS = 60L * 60 * 1000

/**
 * What the device has been doing, from the samples the supervisor writes.
 *
 * Charts are drawn on a Canvas rather than pulled from a charting library: the series is
 * a few hundred points of two values, which is not worth a megabyte of dependency or the
 * startup cost.
 */
@Composable
fun MetricsScreen(snapshot: Protocol.Snapshot?) {
    val context = LocalContext.current
    var windowHours by remember { mutableStateOf(24) }

    // Canvas draw scope is not composable, so colours are resolved here.
    val barColor = MaterialTheme.colorScheme.primary

    // Keyed on the window only, and read off the main thread: this used to be keyed on
    // `snapshot` as well, so every status refresh re-read and re-parsed the entire file on
    // the Compose main dispatcher.
    val samples by
        produceState<List<Metrics.Sample>>(initialValue = emptyList(), windowHours) {
            value = Metrics.load(context, windowHours * HOUR_MS)
        }

    Column(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        // No headline: this renders inside Advanced → Usage now (W8). A second "Metrics" title
        // under the Advanced one was a page pretending to be a page.
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf(24, 168).forEach { hours ->
                UiChoice(
                    label = if (hours == 24) "24h" else "7d",
                    selected = windowHours == hours,
                ) { windowHours = hours }
            }
        }

        if (samples.isEmpty()) {
            Text(
                "Collecting — no samples yet.\n\n" +
                    "The supervisor records one sample every five minutes, so the first " +
                    "point appears within five minutes of the app running.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        } else {
            Section("Memory")
            Panel {
                Text(
                    "available MB · ${samples.size} sample(s)",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                // F31: the axis says what the numbers are, and which end is good. Without the
                // high/low labels the chart was a line with no scale, and a falling line read as
                // a fault even when 600 MB free is perfectly healthy.
                Row(
                    Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Column(Modifier.width(46.dp), horizontalAlignment = Alignment.End) {
                        Text(
                            "${samples.maxOf { it.memMb }} MB",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Spacer(Modifier.height(28.dp))
                        Text(
                            "${samples.minOf { it.memMb }} MB",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    LineChart(
                        points = samples.map { it.memMb.toFloat() },
                        modifier = Modifier.weight(1f).height(64.dp),
                        // A neutral series colour: this is a healthy measurement, and painting
                        // it in the error colour made every phone look alarmed.
                        color = MaterialTheme.colorScheme.primary,
                        // A Canvas is invisible to a screen reader. Without this, the whole
                        // Memory panel was silent apart from its low/high caption.
                        description =
                            "Memory available over the last $windowHours hours: low " +
                                "${samples.minOf { it.memMb }} MB, high ${samples.maxOf { it.memMb }} MB.",
                    )
                }
                Text(
                    "low ${samples.minOf { it.memMb }} MB · high ${samples.maxOf { it.memMb }} MB",
                    style = MaterialTheme.typography.labelSmall,
                )
            }

            Section("Swap free")
            Panel {
                Text(
                    "free swap in MB · higher is better",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                LineChart(
                    points = samples.map { it.swapMb.toFloat() },
                    modifier = Modifier.fillMaxWidth().height(48.dp),
                    color = MaterialTheme.colorScheme.primary,
                    description =
                        "Free swap over the last $windowHours hours: from " +
                            "${samples.minOf { it.swapMb }} MB to ${samples.maxOf { it.swapMb }} MB.",
                )
            }

            snapshot?.let { s ->
                Section("Allocation")
                Panel {
                    if (s.services.isEmpty()) {
                        // Same distinction as the supervisor's notification: an empty list on
                        // a phone with nothing installed is not "none running", it is "none
                        // installed yet".
                        val installed = s.tools.installed.count { it.value }
                        Text(
                            if (installed == 0) "Nothing installed yet." else "No services running.",
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                    val total = max(1, s.services.sumOf { it.memMb })
                    s.services.sortedByDescending { it.memMb }.forEach { sv ->
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(sv.name, style = MaterialTheme.typography.bodySmall, modifier = Modifier.width(90.dp))
                            Box(Modifier.weight(1f)) {
                                Row(Modifier.fillMaxWidth()) {
                                    Box(
                                        Modifier
                                            .fillMaxWidth(sv.memMb.toFloat() / total)
                                            .height(8.dp)
                                            .padding(end = 2.dp),
                                    ) {
                                        Canvas(Modifier.fillMaxWidth().height(8.dp)) {
                                            drawRect(barColor)
                                        }
                                    }
                                }
                            }
                            Text("${sv.memMb} MB", style = MaterialTheme.typography.labelSmall)
                        }
                    }
                }
            }

            Section("Events")
            Panel {
                val events = remember(samples) { transitions(samples) }
                if (events.isEmpty()) {
                    Text(
                        "No service-count changes in this window.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                } else {
                    events.forEach { (ts, text) ->
                        Text(
                            "${formatTime(ts)}  $text",
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
            }
        }
    }
}

// Immutable and thread-safe; the old per-row SimpleDateFormat allocated an object per label
// per recomposition, and java.time is native at minSdk 28.
private val TIME_FMT: DateTimeFormatter = DateTimeFormatter.ofPattern("MM-dd HH:mm", Locale.US)

private fun formatTime(ts: Long): String = TIME_FMT.format(Instant.ofEpochMilli(ts).atZone(ZoneId.systemDefault()))

/** Service-count changes, which is what a restart or an LMK kill looks like in the data. */
private fun transitions(samples: List<Metrics.Sample>): List<Pair<Long, String>> {
    val out = mutableListOf<Pair<Long, String>>()
    var previous = samples.firstOrNull()?.services
    samples.drop(1).forEach { s ->
        if (previous != null && s.services != previous) {
            out += s.ts to "services $previous → ${s.services}"
        }
        previous = s.services
    }
    return out.takeLast(12).reversed()
}

@Composable
private fun LineChart(
    points: List<Float>,
    modifier: Modifier,
    color: Color,
    description: String = "",
) {
    Canvas(
        if (description.isBlank()) {
            modifier
        } else {
            modifier.semantics { contentDescription = description }
        },
    ) {
        if (points.size < 2) return@Canvas
        // Downsample to about the pixel width: one path segment per point on a 7-day
        // window would be thousands of segments for no visible gain.
        val target = minOf(points.size, size.width.toInt().coerceAtLeast(2))
        val step = points.size.toFloat() / target
        val reduced =
            (0 until target).map { i ->
                val from = (i * step).toInt()
                val to = minOf(points.size, ((i + 1) * step).toInt().coerceAtLeast(from + 1))
                points.subList(from, to).average().toFloat()
            }

        val high = reduced.max().coerceAtLeast(1f)
        val path = Path()
        reduced.forEachIndexed { i, value ->
            val x = i * size.width / (reduced.size - 1)
            val y = size.height - (value / high) * size.height
            if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        drawPath(path, color, style = Stroke(width = 2.dp.toPx()))
    }
}

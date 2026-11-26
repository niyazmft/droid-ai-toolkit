package dev.droidai.launcher

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The live-progress feed (Task 17).
 *
 * The engine writes one NDJSON line per step transition; the app only needs the last one. What
 * matters here is that a malformed or stale line degrades to "nothing to show" rather than to a
 * wrong step — a banner that claims "Step 7 of 7 · Install Pi" while an install is at step 2 is
 * worse than a banner with only an elapsed time.
 */
class ProgressTest {
    @Test
    fun `a step line becomes a label`() {
        val step =
            Progress.parse(
                """{"run":"r","action":"pi.install","index":3,"total":7,"step":"install","title":"Install Pi","state":"running","ts":1795641161000}""",
            )
        assertEquals("Install Pi", step?.title)
        assertEquals(3, step?.index)
        assertEquals("Step 3 of 7 · Install Pi", step?.let { Progress.label(it) })
    }

    @Test
    fun `an unknown total still reads sensibly`() {
        val step =
            Progress.parse(
                """{"index":0,"total":0,"title":"Starting","state":"running","ts":1}""",
            )
        assertEquals("Starting", step?.let { Progress.label(it) })
    }

    @Test
    fun `junk is nothing to show, not a wrong step`() {
        assertNull(Progress.parse("not json"))
        assertNull(Progress.parse(""))
        // A line that parses but carries no title must not become a step.
        assertEquals("", Progress.parse("""{"index":3,"total":7}""")?.let { Progress.label(it) })
    }

    @Test
    fun `a finished run has no step to show`() {
        val step = Progress.parse("""{"index":7,"total":7,"title":"","state":"finished","ts":1}""")
        assertEquals("finished", step?.state)
        // The banner filters on `state == "running"`, so this must not render as a step.
        assertEquals("", step?.let { Progress.label(it) })
    }
}

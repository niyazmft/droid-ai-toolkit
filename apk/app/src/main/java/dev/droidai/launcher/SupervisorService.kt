package dev.droidai.launcher

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Watches the toolkit — when the phone is in your hand, not on a clock.
 *
 * ## Why there is no timer
 *
 * The old version polled `--api status` every 60 s. That run measured 22.6 s wall / 18.9 s
 * of user CPU on 8x, because every tool version probe starts a whole Node or Python
 * runtime — but the CPU was only half the cost. Each poll also **woke Termux**, and a
 * runtime that is woken every minute never falls into doze. On a phone whose whole problem
 * is that Android kills background processes for memory, spending the battery budget on
 * asking "are you still there?" is the wrong trade.
 *
 * So the check is now driven by the user reaching for the phone: `ACTION_USER_PRESENT`
 * (unlock) and `ACTION_SCREEN_ON`. The work happens in a moment that costs nothing extra,
 * because the screen is already awake and lit.
 *
 * What this gives up, deliberately: if the runtime dies while the phone sits untouched all
 * night, nobody is told until morning. That is the point — an idle phone should be idle.
 *
 * ## Why it is still a foreground service
 *
 * `ACTION_SCREEN_ON` and `ACTION_USER_PRESENT` cannot be delivered to a manifest-registered
 * receiver on Android 8+, so the process has to be alive to hold a runtime receiver. A
 * foreground service is the only sanctioned way to stay alive, and Android requires it to
 * show a notification. Between wake-ups the service does nothing at all: no timers, no
 * wakelocks, no polling.
 */
class SupervisorService : Service() {
    private val job = SupervisorJob()

    /**
     * Main-confined on purpose.
     *
     * The receiver callbacks arrive on the main thread and [Runner] serialises its own state
     * under a lock, so running the checks on `Dispatchers.Main.immediate` makes every field
     * below single-threaded by construction. The work that used to justify a background
     * dispatcher is a suspending command, not a blocking call: `tick()` waits on a flow, and
     * the metric write hops to IO itself.
     */
    private val scope = CoroutineScope(job + Dispatchers.Main.immediate)

    // Touched only from the main thread (see [scope]).
    private var lastCheckAt = 0L

    /**
     * Consecutive checks that found a problem (0 = the last one was fine).
     *
     * A counter rather than a boolean because the retry interval grows with it: a crash-looping
     * gateway was being re-checked every 60 s for as long as the phone was being unlocked, which
     * is real CPU and real battery for a verdict that had not changed.
     */
    private var unhealthyChecks = 0
    private var checkInFlight = false
    private var lastSampleAt = 0L

    /** Last text actually posted, so an unchanged status does not touch the shade. */
    private var postedTitle: String? = null
    private var postedText: String? = null

    private val screenReceiver =
        object : BroadcastReceiver() {
            override fun onReceive(
                context: Context,
                intent: Intent,
            ) {
                when (intent.action) {
                    Intent.ACTION_USER_PRESENT, Intent.ACTION_SCREEN_ON -> maybeCheck()
                }
            }
        }

    override fun onCreate() {
        super.onCreate()
        Prefs.init(this)
        createChannel()
        // The type is passed explicitly on API 34+: the platform verifies it against the
        // manifest declaration *and* the FOREGROUND_SERVICE_SPECIAL_USE grant, which is the
        // check that a `dataSync` declaration without FOREGROUND_SERVICE_DATA_SYNC was failing.
        post(notification("Starting…", "watching the toolkit"))
        postedTitle = "Starting…"
        postedText = "watching the toolkit"

        val filter =
            IntentFilter().apply {
                addAction(Intent.ACTION_USER_PRESENT)
                addAction(Intent.ACTION_SCREEN_ON)
            }
        ContextCompat.registerReceiver(
            this,
            screenReceiver,
            filter,
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )

        // One check now, so the notification says something true from the first moment
        // rather than "Starting…" until the user happens to unlock. Skipped when the app's
        // own startup probe is in flight or just finished (see [maybeCheck]): that check would
        // either contend for the single command slot or duplicate work already done.
        maybeCheck(force = true)
    }

    override fun onStartCommand(
        intent: Intent?,
        flags: Int,
        startId: Int,
    ): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        // Re-post on every start. On API 33+ the first post can happen before the user grants
        // POST_NOTIFICATIONS, and the notification is then invisible while the service runs;
        // an unchanged status never calls update(), so it would stay invisible until the next
        // unlock. Starting the service again after the grant is what makes "Allow" take effect.
        post(notification(postedTitle ?: "Starting…", postedText ?: "watching the toolkit"))
        return START_STICKY
    }

    /**
     * Run a check, but not more often than the situation deserves.
     *
     * Healthy results are re-checked at most every five minutes; a problem backs off from one
     * minute to thirty (see [SupervisorPolicy.gapMs]), so unlocking your phone four times in a
     * row never means four full status runs, and a crash-looping service is not re-measured
     * every minute for as long as the phone is in use.
     *
     * A **busy** transport is not a fault. The app's launch probe and the supervisor's first
     * check used to race for the single command slot; the loser returned `false`, which marked a
     * healthy device unhealthy and dropped it into the fast retry cadence. Busy now leaves the
     * verdict alone and starts nothing.
     */
    private fun maybeCheck(force: Boolean = false) {
        val now = System.currentTimeMillis()
        val minGap = SupervisorPolicy.gapMs(unhealthyChecks)
        if (!force && now - lastCheckAt < minGap) return
        // Nothing to learn, and something to lose: a check that shares the transport with a
        // user's install either loses the race or delays it.
        if (checkInFlight || Runner.running.value) return
        // Just finished: a forced check at startup would re-read what the probe just answered.
        if (now - Runner.lastFinishedAt.value < SETTLE_MS) return
        checkInFlight = true
        lastCheckAt = now
        scope.launch {
            try {
                val result = tick()
                unhealthyChecks = SupervisorPolicy.nextUnhealthyCount(unhealthyChecks, result)
                // The verdict and the backoff are the two things this service exists to decide,
                // and neither is visible from the notification when the answer is "fine". One
                // line per check makes a field report ("it re-checks constantly") answerable.
                val next = SupervisorPolicy.gapMs(unhealthyChecks) / 1000
                Log.i(TAG, "check $result (consecutive problems: $unhealthyChecks, next in ${next}s)")
            } finally {
                checkInFlight = false
            }
        }
    }

    /** @return how this check ended; [CheckResult.BUSY] changes nothing. */
    private suspend fun tick(): CheckResult {
        if (!Gate.termuxInstalled.value) {
            update("Termux is not installed", "install it from F-Droid")
            return CheckResult.UNHEALTHY
        }

        // Do not send RUN_COMMAND while the gate is closed for policy reasons: Termux
        // replies by posting its own sticky "Plugin Execution Command Error" notification
        // (FLAG_ONGOING_EVENT, never cancelled). A 60 s poll once produced 939 of them in a
        // day on 8x.
        if (Gate.probe.value == Probe.DENIED || Gate.probe.value == Probe.NO_TOOLKIT) {
            update("Setup is not finished", "open the app to complete the one-time step")
            return CheckResult.UNHEALTHY
        }

        if (Runner.running.value) return CheckResult.BUSY

        Runner.send(this, listOf("--api", "status", "--fast"), Origin.SYSTEM, "Read device status")
        val result = withTimeoutOrNull(TIMEOUT_MS) { Runner.result.filterNotNull().first() }
        if (result == null || !result.ok) {
            update("Termux is not responding", "tap to open Termux")
            return CheckResult.UNHEALTHY
        }
        val snapshot = Protocol.snapshot(result.stdout)
        if (snapshot == null) {
            update("Toolkit returned no status", "tap to open the app")
            return CheckResult.UNHEALTHY
        }

        val running = snapshot.services.count { it.status == "online" }
        val mem = snapshot.services.sumOf { it.memMb }

        val verdict =
            SupervisorPolicy.classify(
                running = running,
                installedTools = snapshot.tools.installed.count { it.value },
                autoStart = Prefs.autoStartGateway.value,
            )

        // Nothing installed means nothing is supposed to run. Counting that as "0 services
        // online" made a fresh phone announce its services were down, try to resurrect them,
        // and claim after three attempts that restarting had not helped — about tools that
        // were never installed. Nothing to watch is healthy, and it needs no polling.
        if (verdict == SupervisorPolicy.Verdict.NOTHING_INSTALLED) {
            Prefs.setRestartAttempts(0)
            update("Nothing installed yet", "pick a tool in Packages when you are ready")
            return CheckResult.HEALTHY
        }

        if (verdict == SupervisorPolicy.Verdict.NO_SERVICES_AUTOSTART_OFF) {
            update(
                "No services online (auto-restart is off)",
                "turn it on in Settings to let the app restart them",
            )
            return CheckResult.UNHEALTHY
        }

        if (verdict == SupervisorPolicy.Verdict.NO_SERVICES) {
            // Observe-only is not enough: Termux is alive (it answered) but nothing is
            // serving. Try to bring it back, a bounded number of times — a broken install
            // must not be restarted forever.
            val attempts = (Prefs.restartAttempts.value + 1).coerceAtMost(MAX_ATTEMPTS)
            Prefs.setRestartAttempts(attempts)
            update(
                "No services online — restarting (attempt $attempts/$MAX_ATTEMPTS)",
                "${snapshot.device.model} · ${snapshot.device.memAvailableMb} MB free",
            )
            if (!Runner.running.value) {
                Runner.send(this, listOf("--api", "run", "service.resurrect"), Origin.SYSTEM)
                withTimeoutOrNull(RESTART_TIMEOUT_MS) { Runner.result.filterNotNull().first() }
            }
            if (attempts >= MAX_ATTEMPTS) {
                update(
                    "Services stayed down after $MAX_ATTEMPTS restarts",
                    "tap to open the app for details",
                )
            }
            return CheckResult.UNHEALTHY
        }

        Prefs.setRestartAttempts(0)

        // One point per five minutes at most: the check itself is now event-driven, so two
        // unlocks in a row must not become two samples.
        val now = System.currentTimeMillis()
        if (now - lastSampleAt >= Metrics.SAMPLE_INTERVAL_MS) {
            lastSampleAt = now
            Metrics.record(
                this,
                Metrics.Sample(
                    ts = now,
                    memMb = snapshot.device.memAvailableMb,
                    swapMb = snapshot.device.swapFreeMb,
                    services = running,
                    rssMb = mem,
                ),
            )
        }

        update(
            "$running service(s) online · $mem MB",
            "${snapshot.device.model} · ${snapshot.device.memAvailableMb} MB free",
        )
        return CheckResult.HEALTHY
    }

    /**
     * Post only when the text changed.
     *
     * `notify()` on every tick was 163 posts in a day, which Android reads as a noisy app
     * and demotes (`post_frequency … demoted=163`). An unchanged status is not news.
     */
    private fun update(
        title: String,
        text: String,
    ) {
        if (title == postedTitle && text == postedText) return
        postedTitle = title
        postedText = text
        getSystemService(NotificationManager::class.java)?.notify(NOTIFICATION_ID, notification(title, text))
    }

    private fun notification(
        title: String,
        text: String,
    ): Notification {
        val open =
            PendingIntent.getActivity(
                this,
                0,
                Intent(this, MainActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        val stop =
            PendingIntent.getService(
                this,
                1,
                Intent(this, SupervisorService::class.java).setAction(ACTION_STOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        return NotificationCompat
            .Builder(this, CHANNEL)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setContentIntent(open)
            .addAction(0, "Stop", stop)
            .build()
    }

    /** `startForeground` with the declared type, which is mandatory from API 34. */
    private fun post(n: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
    }

    private fun createChannel() {
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL) == null) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "Toolkit supervisor", NotificationManager.IMPORTANCE_LOW),
            )
        }
    }

    override fun onDestroy() {
        runCatching { unregisterReceiver(screenReceiver) }
        scope.cancel()
        runCatching {
            getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_ID)
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val TAG = "DroidAI"

        private const val CHANNEL = "supervisor"
        private const val NOTIFICATION_ID = 42

        /**
         * Leave a run that just finished alone.
         *
         * The startup probe and the supervisor start in the same second; a check that follows the
         * probe by less than this would either contend for the transport or repeat its answer.
         */
        private const val SETTLE_MS = 10_000L

        /** A status run measured 22.6 s; the fast form 7.2 s. 45 s leaves room for both. */
        private const val TIMEOUT_MS = 45_000L
        private const val RESTART_TIMEOUT_MS = 90_000L
        private const val MAX_ATTEMPTS = 3
        const val ACTION_STOP = "dev.droidai.launcher.SUPERVISOR_STOP"

        fun start(context: Context) {
            val intent = Intent(context, SupervisorService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /**
         * Turn the supervisor off.
         *
         * stopService rather than the STOP action: sending the action to a stopped service
         * would start it first, post a "Starting…" notification, then stop — a visible
         * flicker for a user who just asked for less of it.
         */
        fun stop(context: Context) {
            runCatching { context.stopService(Intent(context, SupervisorService::class.java)) }
            runCatching {
                context.getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_ID)
            }
        }
    }
}

/**
 * How a supervisor check ended.
 *
 * Three states, not two, because "I could not look" is not "it is broken". The launch probe and
 * the supervisor's first check compete for one command slot; when a check lost that race it used
 * to return `false` and mark a working device unhealthy, dropping it into the retry cadence.
 */
internal enum class CheckResult {
    HEALTHY,

    /** Something is genuinely wrong: the phone answered, and the answer was bad. */
    UNHEALTHY,

    /** The transport was busy or a run had just finished. Learns nothing, changes nothing. */
    BUSY,
}

/**
 * What the supervisor should say, given what the phone is actually running.
 *
 * Extracted, and tested, because the empty-device case was wrong in a way that only a phone
 * with nothing installed could show: the app reported "Services are down and restarting did
 * not help" — twice over — to a device that had never installed a tool. The supervisor runs
 * from first launch, so "0 online" is the *normal* state until the user installs something.
 */
internal object SupervisorPolicy {
    enum class Verdict {
        /** No tool installed: nothing is expected to run, so nothing is wrong. */
        NOTHING_INSTALLED,

        /** A tool exists, nothing is online, and auto-start is off — say so, do not restart. */
        NO_SERVICES_AUTOSTART_OFF,

        /** A tool exists and nothing is online: worth a bounded number of restarts. */
        NO_SERVICES,

        HEALTHY,
    }

    /**
     * Consecutive unhealthy checks → the interval to wait before asking again.
     *
     * 1 → 5 → 15 → 30 minutes, then 30 forever. One minute is right for the first retry (a
     * service that died because the phone was asleep comes back quickly), but a gateway in a
     * restart loop stays broken for hours, and re-measuring it every minute costs a full status
     * run — the most expensive thing this app does — on every unlock.
     *
     * A healthy check resets [unhealthyChecks] to 0, which returns [HEALTHY_GAP_MS].
     */
    fun gapMs(unhealthyChecks: Int): Long =
        if (unhealthyChecks <= 0) {
            HEALTHY_GAP_MS
        } else {
            RETRY_STEPS_MS[(unhealthyChecks - 1).coerceAtMost(RETRY_STEPS_MS.lastIndex)]
        }

    /**
     * The next consecutive-unhealthy count.
     *
     * [CheckResult.BUSY] deliberately leaves it untouched: a busy slot is an absence of
     * information, and treating it as a failure was the bug (and, worse, the counter drives the
     * backoff — so a handful of unlucky races would have stretched the retry interval to 30
     * minutes and hidden a real problem).
     */
    fun nextUnhealthyCount(
        current: Int,
        result: CheckResult,
    ): Int =
        when (result) {
            CheckResult.HEALTHY -> 0
            CheckResult.UNHEALTHY -> current + 1
            CheckResult.BUSY -> current
        }

    /** Re-check at most this often when everything is fine. */
    const val HEALTHY_GAP_MS = 5 * 60_000L

    /** Retry intervals while something is wrong, in order. */
    private val RETRY_STEPS_MS =
        longArrayOf(
            1 * 60_000L,
            5 * 60_000L,
            15 * 60_000L,
            30 * 60_000L,
        )

    fun classify(
        running: Int,
        installedTools: Int,
        autoStart: Boolean,
    ): Verdict =
        when {
            // Online services decide first: a device can be serving from a package this
            // build does not recognise as installed, and reporting "nothing installed"
            // over a live gateway would be the same mistake in the other direction.
            running > 0 -> Verdict.HEALTHY
            installedTools == 0 -> Verdict.NOTHING_INSTALLED
            !autoStart -> Verdict.NO_SERVICES_AUTOSTART_OFF
            else -> Verdict.NO_SERVICES
        }
}

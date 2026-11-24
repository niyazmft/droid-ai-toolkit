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
    private var lastHealthy = true
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
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification("Starting…", "watching the toolkit"),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification("Starting…", "watching the toolkit"))
        }
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
        // rather than "Starting…" until the user happens to unlock.
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
        return START_STICKY
    }

    /**
     * Run a check, but not more often than the situation deserves.
     *
     * Healthy results are re-checked at most every five minutes, and a problem at most
     * every minute: unlocking your phone four times in a row should not mean four full
     * status runs.
     */
    private fun maybeCheck(force: Boolean = false) {
        val now = System.currentTimeMillis()
        val minGap = if (lastHealthy) HEALTHY_GAP_MS else TROUBLE_GAP_MS
        if (!force && now - lastCheckAt < minGap) return
        if (checkInFlight) return
        checkInFlight = true
        lastCheckAt = now
        scope.launch {
            try {
                lastHealthy = tick()
            } finally {
                checkInFlight = false
            }
        }
    }

    /** @return true when the device looks healthy. */
    private suspend fun tick(): Boolean {
        if (!Gate.termuxInstalled.value) {
            update("Termux is not installed", "install it from F-Droid")
            return false
        }

        // Do not send RUN_COMMAND while the gate is closed for policy reasons: Termux
        // replies by posting its own sticky "Plugin Execution Command Error" notification
        // (FLAG_ONGOING_EVENT, never cancelled). A 60 s poll once produced 939 of them in a
        // day on 8x.
        if (Gate.probe.value == Probe.DENIED || Gate.probe.value == Probe.NO_TOOLKIT) {
            update("Setup is not finished", "open the app to complete the one-time step")
            return false
        }

        if (Runner.running.value) return false

        Runner.send(this, listOf("--api", "status", "--fast"), Origin.SYSTEM, "Read device status")
        val result = withTimeoutOrNull(TIMEOUT_MS) { Runner.result.filterNotNull().first() }
        if (result == null || !result.ok) {
            update("Termux is not responding", "tap to open Termux")
            return false
        }
        val snapshot = Protocol.snapshot(result.stdout)
        if (snapshot == null) {
            update("Toolkit returned no status", "tap to open the app")
            return false
        }

        val running = snapshot.services.count { it.status == "online" }
        val mem = snapshot.services.sumOf { it.memMb }

        if (running == 0 && !Prefs.autoStartGateway.value) {
            update(
                "No services online (auto-start is off)",
                "turn it on in Settings to let the supervisor restart the gateway",
            )
            return false
        }

        if (running == 0) {
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
                    "Services are down and restarting did not help",
                    "tap to open the app for details",
                )
            }
            return false
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
        return true
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
        private const val CHANNEL = "supervisor"
        private const val NOTIFICATION_ID = 42

        /** Re-check at most this often when everything is fine. */
        private const val HEALTHY_GAP_MS = 5 * 60_000L

        /** …and this often while something is wrong, so a fix shows up quickly. */
        private const val TROUBLE_GAP_MS = 60_000L

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

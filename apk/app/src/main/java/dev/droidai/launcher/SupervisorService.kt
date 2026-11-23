package dev.droidai.launcher

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Watches the toolkit and says so.
 *
 * It cannot stop Android from killing Termux — nothing can. What it can do is hold a
 * foreground service (a low oom_score_adj for this process, and a visible notification
 * that cannot be silently dropped) and turn "the gateway went quiet" into "Termux is not
 * responding — tap to open".
 *
 * The check is a real `--api status` run, not a package check: the package and the
 * permission both survive a process kill, which is exactly the case that fooled the
 * app earlier.
 *
 * ## Why the cadence is not a fixed minute
 *
 * That status run is expensive: measured on 8x it is 22.6 s wall and **18.9 s of user
 * CPU**, because it shells out to `node`, `pm2`, `openclaw --version` and friends. Polling
 * it every 60 s kept roughly a third of a core busy forever, drained the battery, and —
 * because each poll also re-posted this notification — earned the channel a demotion from
 * Android (`post_frequency … demoted=163` in one day).
 *
 * So: poll slowly while everything is healthy, quickly only while something is wrong, and
 * not at all while the device is dozing. Re-checking a working device every five minutes
 * cannot realistically miss a failure the user would notice sooner by opening the app.
 */
class SupervisorService : Service() {
    private val job = SupervisorJob()
    private var scope = CoroutineScope(job + Dispatchers.Default)
    private var loop: Job? = null
    private var attempts = 0
    private var lastSampleAt = 0L

    /** Last text actually posted, so an unchanged status does not touch the shade. */
    private var postedTitle: String? = null
    private var postedText: String? = null

    override fun onCreate() {
        super.onCreate()
        Prefs.init(this)
        createChannel()
        startForeground(NOTIFICATION_ID, notification("Starting…", "watching the toolkit"))
        postedTitle = "Starting…"
        postedText = "watching the toolkit"
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
        if (loop?.isActive != true) {
            loop =
                scope.launch {
                    while (isActive) {
                        val healthy = tick()
                        delay(if (healthy) INTERVAL_HEALTHY_MS else INTERVAL_TROUBLE_MS)
                    }
                }
        }
        return START_STICKY
    }

    /** @return true when the device looks healthy, which is what slows the next poll down. */
    private suspend fun tick(): Boolean {
        if (!Gate.termuxInstalled.value) {
            update("Termux is not installed", "install it from F-Droid")
            return false
        }

        // Do not send RUN_COMMAND while the gate is closed for policy reasons. Termux
        // answers such a request by posting its own *sticky* "Plugin Execution Command
        // Error" notification (FLAG_ONGOING_EVENT, never cancelled), so a supervisor
        // polling every minute turns one wrong setting into an un-dismissable error in
        // the shade. Observed on 8x: 939 notifications from com.termux in a day.
        //
        // UNREACHABLE deliberately still polls: detecting a dead Termux is this service's
        // whole purpose, and a request that gets no answer posts no notification.
        if (Gate.probe.value == Probe.DENIED || Gate.probe.value == Probe.NO_TOOLKIT) {
            update("Setup is not finished", "open the app to complete the one-time step")
            return false
        }

        // A status run wakes Termux and spends ~19 s of CPU; an idle device should not pay
        // that. The next tick after the screen wakes up catches up anyway, and the app
        // probes on open.
        if (isDozing()) return true

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
            // Observe-only is not enough: Termux is alive (the probe answered) but nothing
            // is serving. Try to bring it back, and stop trying after a few attempts — a
            // broken install must not be restarted forever.
            if (attempts < MAX_ATTEMPTS) {
                attempts++
                update(
                    "No services online — restarting (attempt $attempts/$MAX_ATTEMPTS)",
                    "${snapshot.device.model} · ${snapshot.device.memAvailableMb} MB free",
                )
                if (!Runner.running.value) {
                    Runner.send(this, listOf("--api", "run", "service.resurrect"), Origin.SYSTEM)
                    withTimeoutOrNull(RESTART_TIMEOUT_MS) { Runner.result.filterNotNull().first() }
                }
            } else {
                update(
                    "Services are down and restarting did not help",
                    "tap to open the app for details",
                )
            }
            return false
        }

        attempts = 0

        // Record one point every five minutes. Reusing this tick means analytics adds no
        // wakeups: the supervisor already asks Termux for a status.
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

    private fun isDozing(): Boolean =
        runCatching {
            getSystemService(PowerManager::class.java)?.isDeviceIdleMode == true
        }.getOrDefault(false)

    /**
     * Post only when the text changed.
     *
     * `notify()` was called on every tick whether or not anything had happened: 163 posts
     * in a day, which Android reads as a noisy app and demotes. An unchanged status is not
     * news.
     */
    private fun update(
        title: String,
        text: String,
    ) {
        if (title == postedTitle && text == postedText) return
        postedTitle = title
        postedText = text
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, notification(title, text))
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
        scope.cancel()
        // Turning the supervisor off must remove the notification too, or the app keeps a
        // permanent entry in the shade for a service that no longer exists.
        runCatching {
            getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_ID)
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val CHANNEL = "supervisor"
        private const val NOTIFICATION_ID = 42

        /** Healthy: a working device does not need checking every minute. */
        private const val INTERVAL_HEALTHY_MS = 5 * 60_000L

        /** Something is wrong: check again soon, but never in a tight loop. */
        private const val INTERVAL_TROUBLE_MS = 60_000L

        /**
         * A status run measured 22.6 s on 8x, so 25 s was a coin flip: the poll could be
         * abandoned a second before the answer arrived, which reads as "Termux is not
         * responding" on a perfectly healthy device.
         */
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
         * stopService rather than the STOP action: sending the action to a stopped
         * service would start it first, post a "Starting…" notification, and then stop —
         * a visible flicker in the shade for a user who just asked for less of it.
         */
        fun stop(context: Context) {
            runCatching { context.stopService(Intent(context, SupervisorService::class.java)) }
            runCatching {
                context.getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_ID)
            }
        }
    }
}

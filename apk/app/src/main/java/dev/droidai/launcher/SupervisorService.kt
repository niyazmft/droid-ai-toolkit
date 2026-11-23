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
 * foreground service (a low oom_score_adj for this process, and a visible
 * notification that cannot be silently dropped) and turn "the gateway went quiet"
 * into "Termux is not responding — tap to open".
 *
 * The check is a real `--api status` run, not a package check: the package and the
 * permission both survive a process kill, which is exactly the case that fooled the
 * app earlier.
 */
class SupervisorService : Service() {
    private val job = SupervisorJob()
    private var scope = CoroutineScope(job + Dispatchers.Default)
    private var loop: Job? = null
    private var attempts = 0
    private var lastSampleAt = 0L

    override fun onCreate() {
        super.onCreate()
        Prefs.init(this)
        createChannel()
        startForeground(NOTIFICATION_ID, notification("Starting…", "watching the toolkit"))
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
                        tick()
                        delay(INTERVAL_MS)
                    }
                }
        }
        return START_STICKY
    }

    private suspend fun tick() {
        if (!Gate.termuxInstalled.value) {
            update("Termux is not installed", "install it from F-Droid")
            return
        }
        if (!Runner.running.value) {
            Runner.send(this, listOf("--api", "status"))
            val result = withTimeoutOrNull(TIMEOUT_MS) { Runner.result.filterNotNull().first() }
            if (result == null || !result.ok) {
                update("Termux is not responding", "tap to open Termux")
                return
            }
            val snapshot = Protocol.snapshot(result.stdout)
            if (snapshot == null) {
                update("Toolkit returned no status", "tap to open the app")
                return
            }
            val running = snapshot.services.count { it.status == "online" }
            val mem = snapshot.services.sumOf { it.memMb }

            if (running == 0 && !Prefs.autoStartGateway.value) {
                update(
                    "No services online (auto-start is off)",
                    "turn it on in Settings to let the supervisor restart the gateway",
                )
                return
            }

            if (running == 0) {
                // Observe-only is not enough: Termux is alive (the probe answered) but
                // nothing is serving. Try to bring it back, and stop trying after a few
                // attempts — a broken install must not be restarted forever.
                if (attempts < MAX_ATTEMPTS) {
                    attempts++
                    update(
                        "No services online — restarting (attempt $attempts/$MAX_ATTEMPTS)",
                        "${snapshot.device.model} · ${snapshot.device.memAvailableMb} MB free",
                    )
                    if (!Runner.running.value) {
                        Runner.send(this, listOf("--api", "run", "service.resurrect"))
                        withTimeoutOrNull(90_000) { Runner.result.filterNotNull().first() }
                    }
                } else {
                    update(
                        "Services are down and restarting did not help",
                        "tap to open the app for details",
                    )
                }
                return
            }

            attempts = 0

            // Record one point every five minutes. Reusing this tick means analytics adds
            // no wakeups: the supervisor already asks Termux for a status every minute.
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
        }
    }

    private fun update(
        title: String,
        text: String,
    ) {
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
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val CHANNEL = "supervisor"
        private const val NOTIFICATION_ID = 42
        private const val INTERVAL_MS = 60_000L
        private const val TIMEOUT_MS = 25_000L
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
    }
}

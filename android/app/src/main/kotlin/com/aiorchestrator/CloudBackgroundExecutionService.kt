package com.aiorchestrator

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * Foreground process-liveness lease shared by user-started Cloud and Cantiere
 * work.
 *
 * The actual inference/build pipelines remain owned by Flutter. This service
 * only raises the Android process priority while already-authorized work is
 * running, so moving the app to the background or turning the screen off does
 * not immediately make that work disposable.
 *
 * The historical class/channel name is retained so existing Cloud callers keep
 * working without a migration or a second Android foreground service.
 */
class CloudBackgroundExecutionService : Service() {
    companion object {
        const val ACTION_START = "com.aiorchestrator.cloud_background.START"
        const val ACTION_STOP = "com.aiorchestrator.cloud_background.STOP"
        const val EXTRA_ACTIVE_LEASES = "activeLeases"
        const val EXTRA_CLOUD_LEASES = "cloudLeases"
        const val EXTRA_WORKSHOP_LEASES = "workshopLeases"

        private const val CHANNEL_ID = "ai_orchestrator_cloud_work"
        private const val CHANNEL_NAME = "AI Orchestrator in background"
        private const val NOTIFICATION_ID = 7312
    }

    override fun onCreate() {
        super.onCreate()
        ensureNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> stopServiceForeground()
            ACTION_START, null -> {
                val fallbackActive =
                    intent?.getIntExtra(EXTRA_ACTIVE_LEASES, 1)?.coerceAtLeast(1) ?: 1
                val cloudLeases = intent
                    ?.getIntExtra(EXTRA_CLOUD_LEASES, fallbackActive)
                    ?.coerceAtLeast(0)
                    ?: fallbackActive
                val workshopLeases = intent
                    ?.getIntExtra(EXTRA_WORKSHOP_LEASES, 0)
                    ?.coerceAtLeast(0)
                    ?: 0
                startForeground(
                    NOTIFICATION_ID,
                    buildNotification(cloudLeases, workshopLeases),
                )
            }
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description =
                "Mantiene attivo il lavoro AI autorizzato mentre l'app è in background."
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(
        cloudLeases: Int,
        workshopLeases: Int,
    ): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            pendingFlags,
        )

        val title: String
        val text: String
        when {
            workshopLeases > 0 && cloudLeases == 0 -> {
                title = "Cantiere in esecuzione"
                text = if (workshopLeases > 1) {
                    "AI Orchestrator sta completando $workshopLeases attività del Cantiere."
                } else {
                    "AI Orchestrator sta completando un'attività del Cantiere."
                }
            }

            cloudLeases > 0 && workshopLeases == 0 -> {
                title = "Elaborazione Cloud in corso"
                text = if (cloudLeases > 1) {
                    "AI Orchestrator sta completando $cloudLeases richieste Cloud."
                } else {
                    "AI Orchestrator sta completando una risposta Cloud."
                }
            }

            else -> {
                title = "AI Orchestrator in esecuzione"
                text = "AI Orchestrator sta completando attività Cloud e del Cantiere."
            }
        }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }

    private fun stopServiceForeground() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }
}

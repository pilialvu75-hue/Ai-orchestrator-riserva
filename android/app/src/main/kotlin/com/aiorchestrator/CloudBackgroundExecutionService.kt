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
 * Foreground process-liveness lease for user-started Cloud inference.
 *
 * The actual HTTP/inference pipeline remains owned by Flutter. This service
 * only raises the Android process priority while an already-authorized Cloud
 * request is running, so moving the app to the background or turning the
 * screen off does not immediately make the request disposable.
 */
class CloudBackgroundExecutionService : Service() {
    companion object {
        const val ACTION_START = "com.aiorchestrator.cloud_background.START"
        const val ACTION_STOP = "com.aiorchestrator.cloud_background.STOP"
        const val EXTRA_ACTIVE_LEASES = "activeLeases"

        private const val CHANNEL_ID = "ai_orchestrator_cloud_work"
        private const val CHANNEL_NAME = "Cloud AI in background"
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
                val activeLeases = intent?.getIntExtra(EXTRA_ACTIVE_LEASES, 1) ?: 1
                startForeground(
                    NOTIFICATION_ID,
                    buildNotification(activeLeases.coerceAtLeast(1)),
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
            description = "Mantiene attiva una risposta Cloud autorizzata mentre l'app è in background."
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(activeLeases: Int): Notification {
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
        val text = if (activeLeases > 1) {
            "AI Orchestrator sta completando $activeLeases richieste Cloud."
        } else {
            "AI Orchestrator sta completando una risposta Cloud."
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Elaborazione Cloud in corso")
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

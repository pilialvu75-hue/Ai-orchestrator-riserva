package com.aiorchestrator

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Platform boundary for keeping an already user-started Cloud response alive
 * after the Activity leaves the foreground.
 *
 * It does not execute HTTP requests itself and never receives prompts,
 * credentials, providers or response content. Flutter keeps owning the existing
 * Cloud pipeline; this service only promotes the process for the duration of an
 * explicit Cloud send.
 */
object CloudBackgroundExecution {
    private const val CHANNEL_NAME = "ai_orchestrator/cloud_background"

    fun register(context: Context, engine: FlutterEngine) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL_NAME)
            .setMethodCallHandler { call, result ->
                val leaseId = call.argument<String>("leaseId")?.trim()
                if (leaseId.isNullOrEmpty()) {
                    result.error("INVALID_ARGUMENT", "leaseId is required", null)
                    return@setMethodCallHandler
                }

                try {
                    when (call.method) {
                        "acquire" -> {
                            CloudBackgroundExecutionService.acquire(app, leaseId)
                            result.success(null)
                        }
                        "release" -> {
                            CloudBackgroundExecutionService.release(leaseId)
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error(
                        "CLOUD_BACKGROUND_EXECUTION",
                        error.message ?: "Cloud background execution unavailable",
                        null
                    )
                }
            }
    }
}

class CloudBackgroundExecutionService : Service() {
    companion object {
        private const val ACTION_ACQUIRE =
            "com.aiorchestrator.cloud_background.ACQUIRE"
        private const val EXTRA_LEASE_ID = "lease_id"
        private const val NOTIFICATION_CHANNEL_ID =
            "ai_orchestrator_cloud_background"
        private const val NOTIFICATION_ID = 4107

        private val lock = Any()

        @Volatile
        private var current: CloudBackgroundExecutionService? = null

        fun acquire(context: Context, leaseId: String) {
            val existing = current
            if (existing != null) {
                existing.acquireLease(leaseId)
                return
            }

            val intent = Intent(
                context.applicationContext,
                CloudBackgroundExecutionService::class.java
            ).apply {
                action = ACTION_ACQUIRE
                putExtra(EXTRA_LEASE_ID, leaseId)
            }
            ContextCompat.startForegroundService(context.applicationContext, intent)
        }

        fun release(leaseId: String) {
            current?.releaseLease(leaseId)
        }
    }

    private val activeLeases = linkedSetOf<String>()

    override fun onCreate() {
        super.onCreate()
        synchronized(lock) {
            current = this
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_ACQUIRE) {
            val leaseId = intent.getStringExtra(EXTRA_LEASE_ID)?.trim()
            if (!leaseId.isNullOrEmpty()) {
                acquireLease(leaseId)
            } else {
                stopSelf(startId)
            }
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        synchronized(lock) {
            activeLeases.clear()
            if (current === this) {
                current = null
            }
        }
        super.onDestroy()
    }

    private fun acquireLease(leaseId: String) {
        synchronized(lock) {
            activeLeases.add(leaseId)
            startForeground(NOTIFICATION_ID, buildNotification())
        }
    }

    private fun releaseLease(leaseId: String) {
        synchronized(lock) {
            activeLeases.remove(leaseId)
            if (activeLeases.isEmpty()) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
                stopSelf()
            }
        }
    }

    private fun buildNotification(): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "Cloud responses",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps user-started Cloud responses running in background"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }

        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("AI Orchestrator")
            .setContentText("Risposta Cloud in elaborazione")
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }
}

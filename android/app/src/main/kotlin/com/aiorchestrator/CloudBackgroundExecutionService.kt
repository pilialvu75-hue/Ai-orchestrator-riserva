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

/**
 * Foreground process-liveness lease shared by user-started Cloud and Cantiere
 * work.
 *
 * The actual inference/build pipelines remain owned by Flutter. This service
 * raises process priority and exposes truthful project progress while
 * owner-started work is still active.
 */
class CloudBackgroundExecutionService : Service() {
    companion object {
        const val ACTION_START = "com.aiorchestrator.cloud_background.START"
        const val ACTION_STOP = "com.aiorchestrator.cloud_background.STOP"
        const val EXTRA_ACTIVE_LEASES = "activeLeases"
        const val EXTRA_CLOUD_LEASES = "cloudLeases"
        const val EXTRA_WORKSHOP_LEASES = "workshopLeases"
        const val EXTRA_WORKSHOP_PROJECT_ID = "workshopProjectId"
        const val EXTRA_WORKSHOP_TITLE = "workshopTitle"
        const val EXTRA_WORKSHOP_PROGRESS = "workshopProgress"
        const val EXTRA_WORKSHOP_COMPLETED_TASKS = "workshopCompletedTasks"
        const val EXTRA_WORKSHOP_TOTAL_TASKS = "workshopTotalTasks"
        const val EXTRA_WORKSHOP_STAGE = "workshopStage"
        const val EXTRA_WORKSHOP_SURFACE_STATUS = "workshopSurfaceStatus"

        private const val GENERAL_CHANNEL_ID = "ai_orchestrator_cloud_work"
        private const val GENERAL_CHANNEL_NAME = "AI Orchestrator in background"
        private const val WORKSHOP_CHANNEL_ID = "ai_orchestrator_workshop_progress"
        private const val WORKSHOP_CHANNEL_NAME = "Cantiere progress"
        private const val FOREGROUND_NOTIFICATION_ID = 7312
        private const val TERMINAL_NOTIFICATION_ID = 7313

        fun cancelWorkshopTerminalNotification(context: Context) {
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.cancel(TERMINAL_NOTIFICATION_ID)
        }

        fun showWorkshopTerminalNotification(
            context: Context,
            title: String,
            outcome: String,
            progress: Int,
        ) {
            ensureWorkshopChannel(context)
            val manager = context.getSystemService(NotificationManager::class.java)
            val pendingIntent = launchPendingIntent(context)
            val normalizedTitle = title.trim().ifEmpty { "Progetto Cantiere" }
            val contentTitle = when (outcome) {
                "completed" -> "Cantiere completato"
                "cancelled" -> "Cantiere annullato"
                "blocked" -> "Cantiere bloccato"
                else -> "Cantiere: errore"
            }
            val contentText = when (outcome) {
                "completed" -> normalizedTitle + " · build completata"
                "cancelled" -> normalizedTitle
                "blocked" -> normalizedTitle + " · intervento richiesto"
                else -> normalizedTitle + " · controlla il Cantiere"
            }

            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, WORKSHOP_CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }

            manager.notify(
                TERMINAL_NOTIFICATION_ID,
                builder
                    .setSmallIcon(R.mipmap.ic_launcher)
                    .setContentTitle(contentTitle)
                    .setContentText(contentText)
                    .setContentIntent(pendingIntent)
                    .setAutoCancel(true)
                    .setOngoing(false)
                    .setOnlyAlertOnce(true)
                    .setCategory(Notification.CATEGORY_STATUS)
                    .setNumber(progress.coerceIn(0, 100))
                    .build(),
            )
        }

        private fun ensureGeneralChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(
                    GENERAL_CHANNEL_ID,
                    GENERAL_CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description =
                        "Mantiene attivo il lavoro AI autorizzato mentre l'app è in background."
                    setShowBadge(false)
                },
            )
        }

        private fun ensureWorkshopChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(
                    WORKSHOP_CHANNEL_ID,
                    WORKSHOP_CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description =
                        "Mostra avanzamento e stato dei progetti del Cantiere in background."
                    setShowBadge(true)
                },
            )
        }

        private fun launchPendingIntent(context: Context): PendingIntent {
            val launchIntent = context.packageManager
                .getLaunchIntentForPackage(context.packageName)
                ?: Intent(context, MainActivity::class.java)
            val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    PendingIntent.FLAG_IMMUTABLE
                } else {
                    0
                }
            return PendingIntent.getActivity(
                context,
                0,
                launchIntent,
                pendingFlags,
            )
        }
    }

    override fun onCreate() {
        super.onCreate()
        ensureGeneralChannel(this)
        ensureWorkshopChannel(this)
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
                    FOREGROUND_NOTIFICATION_ID,
                    buildNotification(
                        cloudLeases = cloudLeases,
                        workshopLeases = workshopLeases,
                        projectId = intent?.getStringExtra(EXTRA_WORKSHOP_PROJECT_ID),
                        projectTitle = intent?.getStringExtra(EXTRA_WORKSHOP_TITLE),
                        progress = intent?.getIntExtra(EXTRA_WORKSHOP_PROGRESS, 0) ?: 0,
                        completedTasks =
                            intent?.getIntExtra(EXTRA_WORKSHOP_COMPLETED_TASKS, 0) ?: 0,
                        totalTasks =
                            intent?.getIntExtra(EXTRA_WORKSHOP_TOTAL_TASKS, 0) ?: 0,
                        stage = intent?.getStringExtra(EXTRA_WORKSHOP_STAGE),
                        surfaceStatus =
                            intent?.getStringExtra(EXTRA_WORKSHOP_SURFACE_STATUS),
                    ),
                )
            }
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun buildNotification(
        cloudLeases: Int,
        workshopLeases: Int,
        projectId: String?,
        projectTitle: String?,
        progress: Int,
        completedTasks: Int,
        totalTasks: Int,
        stage: String?,
        surfaceStatus: String?,
    ): Notification {
        val pendingIntent = launchPendingIntent(this)
        val normalizedProgress = progress.coerceIn(0, 100)
        val hasProject = workshopLeases > 0 &&
            !projectId.isNullOrBlank() &&
            !projectTitle.isNullOrBlank()
        val channelId =
            if (hasProject) WORKSHOP_CHANNEL_ID else GENERAL_CHANNEL_ID

        val title: String
        val text: String
        var showProgress = false
        var indeterminate = false

        when {
            hasProject -> {
                title = "Cantiere · " + projectTitle!!.trim()
                val stageLabel = stageLabel(stage)
                if (surfaceStatus == "build") {
                    text = "Task 100% · build finale in corso"
                    showProgress = true
                    indeterminate = true
                } else if (totalTasks > 0) {
                    text = normalizedProgress.toString() + "% · task " +
                        completedTasks.toString() + "/" + totalTasks.toString() +
                        " · " + stageLabel
                    showProgress = true
                } else {
                    text = stageLabel + " in corso"
                    showProgress = true
                    indeterminate = true
                }
            }

            workshopLeases > 0 && cloudLeases == 0 -> {
                title = "Cantiere in esecuzione"
                text = if (workshopLeases > 1) {
                    "AI Orchestrator sta completando " +
                        workshopLeases.toString() + " attività del Cantiere."
                } else {
                    "AI Orchestrator sta completando un'attività del Cantiere."
                }
            }

            cloudLeases > 0 && workshopLeases == 0 -> {
                title = "Elaborazione Cloud in corso"
                text = if (cloudLeases > 1) {
                    "AI Orchestrator sta completando " +
                        cloudLeases.toString() + " richieste Cloud."
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
            Notification.Builder(this, channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)

        if (hasProject) {
            builder
                .setSubText(
                    if (surfaceStatus == "build") {
                        "Build finale"
                    } else {
                        normalizedProgress.toString() + "%"
                    },
                )
                .setNumber(normalizedProgress)
        }
        if (showProgress) {
            builder.setProgress(
                if (indeterminate) 0 else 100,
                if (indeterminate) 0 else normalizedProgress,
                indeterminate,
            )
        }

        return builder.build()
    }

    private fun stageLabel(stage: String?): String = when (stage?.trim()) {
        "analysis" -> "Orchestratore"
        "planning" -> "Architect"
        "implementation" -> "Engineer"
        "review" -> "Reviewer"
        "validation" -> "Validation"
        "completed" -> "Task completati"
        else -> "Progetto"
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

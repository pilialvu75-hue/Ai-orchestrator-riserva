package com.aiorchestrator

import android.content.Context
import android.content.Intent
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Collections

/** Flutter bridge for ref-counted foreground execution leases.
 *
 * The historical channel/service name is kept for backwards compatibility with
 * Cloud inference, but the same process-liveness service is shared with the
 * Cantiere so Android does not run two competing foreground services.
 */
object CloudBackgroundExecutionBridge {
    private const val CHANNEL_NAME = "ai_orchestrator/cloud_background_execution"
    private const val KIND_CLOUD = "cloud"
    private const val KIND_WORKSHOP = "workshop"
    private const val PROJECT_LEASE_PREFIX = "workshop-project:"

    private data class WorkshopProjectNotification(
        val projectId: String,
        val title: String,
        val progress: Int,
        val completedTasks: Int,
        val totalTasks: Int,
        val stage: String,
        val surfaceStatus: String,
    )

    private val activeLeases =
        Collections.synchronizedMap(mutableMapOf<String, String>())

    @Volatile
    private var workshopProject: WorkshopProjectNotification? = null

    fun register(context: Context, engine: FlutterEngine) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL_NAME)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "acquire" -> {
                            val leaseId = requireNotNull(call.argument<String>("leaseId")) {
                                "leaseId is required"
                            }
                            val kind = normalizeKind(call.argument<String>("kind"))
                            val added = synchronized(activeLeases) {
                                if (activeLeases.containsKey(leaseId)) {
                                    false
                                } else {
                                    activeLeases[leaseId] = kind
                                    true
                                }
                            }
                            if (added) {
                                try {
                                    startService(app)
                                } catch (error: Exception) {
                                    activeLeases.remove(leaseId)
                                    throw error
                                }
                            }
                            result.success(statusPayload(acquired = added))
                        }

                        "release" -> {
                            val leaseId = requireNotNull(call.argument<String>("leaseId")) {
                                "leaseId is required"
                            }
                            activeLeases.remove(leaseId)
                            refreshOrStop(app)
                            result.success(statusPayload())
                        }

                        "beginWorkshopProject" -> {
                            val project = workshopProjectFrom(call)
                            val leaseId = projectLeaseId(project.projectId)
                            synchronized(activeLeases) {
                                activeLeases[leaseId] = KIND_WORKSHOP
                            }
                            workshopProject = project
                            CloudBackgroundExecutionService
                                .cancelWorkshopTerminalNotification(app)
                            startService(app)
                            result.success(statusPayload(acquired = true))
                        }

                        "updateWorkshopProject" -> {
                            val project = workshopProjectFrom(call)
                            val leaseId = projectLeaseId(project.projectId)
                            synchronized(activeLeases) {
                                activeLeases[leaseId] = KIND_WORKSHOP
                            }
                            workshopProject = project
                            startService(app)
                            result.success(statusPayload())
                        }

                        "finishWorkshopProject" -> {
                            val project = workshopProjectFrom(call)
                            val outcome =
                                call.argument<String>("outcome")?.trim()?.lowercase()
                                    ?.ifEmpty { "failed" }
                                    ?: "failed"
                            activeLeases.remove(projectLeaseId(project.projectId))
                            workshopProject = null
                            refreshOrStop(app)
                            CloudBackgroundExecutionService
                                .showWorkshopTerminalNotification(
                                    context = app,
                                    title = project.title,
                                    outcome = outcome,
                                    progress = project.progress,
                                )
                            result.success(statusPayload())
                        }

                        "clearWorkshopProject" -> {
                            val projectId =
                                call.argument<String>("projectId")?.trim().orEmpty()
                            if (projectId.isNotEmpty()) {
                                activeLeases.remove(projectLeaseId(projectId))
                            }
                            if (workshopProject?.projectId == projectId ||
                                projectId.isEmpty()
                            ) {
                                workshopProject = null
                            }
                            refreshOrStop(app)
                            result.success(statusPayload())
                        }

                        "status" -> result.success(statusPayload())

                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error(
                        "CLOUD_BACKGROUND_EXECUTION",
                        error.message ?: error.javaClass.simpleName,
                        null,
                    )
                }
            }
    }

    private fun workshopProjectFrom(call: MethodCall): WorkshopProjectNotification {
        val projectId = requireNotNull(call.argument<String>("projectId")) {
            "projectId is required"
        }.trim()
        require(projectId.isNotEmpty()) { "projectId cannot be empty" }

        val title = call.argument<String>("title")?.trim().orEmpty()
            .ifEmpty { "Progetto Cantiere" }

        return WorkshopProjectNotification(
            projectId = projectId,
            title = title,
            progress = (call.argument<Int>("progress") ?: 0).coerceIn(0, 100),
            completedTasks =
                (call.argument<Int>("completedTasks") ?: 0).coerceAtLeast(0),
            totalTasks = (call.argument<Int>("totalTasks") ?: 0).coerceAtLeast(0),
            stage = call.argument<String>("stage")?.trim().orEmpty(),
            surfaceStatus =
                call.argument<String>("surfaceStatus")?.trim()?.lowercase().orEmpty(),
        )
    }

    private fun projectLeaseId(projectId: String): String =
        PROJECT_LEASE_PREFIX + projectId

    private fun normalizeKind(raw: String?): String =
        if (raw?.trim()?.lowercase() == KIND_WORKSHOP) KIND_WORKSHOP else KIND_CLOUD

    private fun statusPayload(acquired: Boolean? = null): Map<String, Any> {
        val (cloudLeases, workshopLeases) = leaseCounts()
        val payload = mutableMapOf<String, Any>(
            "activeLeases" to (cloudLeases + workshopLeases),
            "cloudLeases" to cloudLeases,
            "workshopLeases" to workshopLeases,
        )
        workshopProject?.let {
            payload["workshopProjectId"] = it.projectId
            payload["workshopProgress"] = it.progress
        }
        if (acquired != null) payload["acquired"] = acquired
        return payload
    }

    private fun leaseCounts(): Pair<Int, Int> = synchronized(activeLeases) {
        var cloudLeases = 0
        var workshopLeases = 0
        activeLeases.values.forEach { kind ->
            if (kind == KIND_WORKSHOP) workshopLeases += 1 else cloudLeases += 1
        }
        Pair(cloudLeases, workshopLeases)
    }

    private fun refreshOrStop(context: Context) {
        if (activeLeases.isEmpty()) {
            context.stopService(
                Intent(context, CloudBackgroundExecutionService::class.java),
            )
        } else {
            startService(context)
        }
    }

    private fun startService(context: Context) {
        val (cloudLeases, workshopLeases) = leaseCounts()
        val activeLeaseCount = cloudLeases + workshopLeases
        val project = workshopProject
        val intent = Intent(context, CloudBackgroundExecutionService::class.java).apply {
            action = CloudBackgroundExecutionService.ACTION_START
            putExtra(
                CloudBackgroundExecutionService.EXTRA_ACTIVE_LEASES,
                activeLeaseCount,
            )
            putExtra(
                CloudBackgroundExecutionService.EXTRA_CLOUD_LEASES,
                cloudLeases,
            )
            putExtra(
                CloudBackgroundExecutionService.EXTRA_WORKSHOP_LEASES,
                workshopLeases,
            )
            if (project != null) {
                putExtra(
                    CloudBackgroundExecutionService.EXTRA_WORKSHOP_PROJECT_ID,
                    project.projectId,
                )
                putExtra(
                    CloudBackgroundExecutionService.EXTRA_WORKSHOP_TITLE,
                    project.title,
                )
                putExtra(
                    CloudBackgroundExecutionService.EXTRA_WORKSHOP_PROGRESS,
                    project.progress,
                )
                putExtra(
                    CloudBackgroundExecutionService.EXTRA_WORKSHOP_COMPLETED_TASKS,
                    project.completedTasks,
                )
                putExtra(
                    CloudBackgroundExecutionService.EXTRA_WORKSHOP_TOTAL_TASKS,
                    project.totalTasks,
                )
                putExtra(
                    CloudBackgroundExecutionService.EXTRA_WORKSHOP_STAGE,
                    project.stage,
                )
                putExtra(
                    CloudBackgroundExecutionService.EXTRA_WORKSHOP_SURFACE_STATUS,
                    project.surfaceStatus,
                )
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }
    }
}

package com.aiorchestrator

import android.content.Context
import android.content.Intent
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
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

    private val activeLeases =
        Collections.synchronizedMap(mutableMapOf<String, String>())

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
                            if (activeLeases.isEmpty()) {
                                // stopService() is legal from the background and does not
                                // attempt to start a new component after the user has left
                                // the foreground.
                                app.stopService(
                                    Intent(app, CloudBackgroundExecutionService::class.java),
                                )
                            } else {
                                // Refresh the notification so it reflects the remaining
                                // Cloud/Cantiere leases.
                                startService(app)
                            }
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

    private fun normalizeKind(raw: String?): String =
        if (raw?.trim()?.lowercase() == KIND_WORKSHOP) KIND_WORKSHOP else KIND_CLOUD

    private fun statusPayload(acquired: Boolean? = null): Map<String, Any> {
        val (cloudLeases, workshopLeases) = leaseCounts()
        val payload = mutableMapOf<String, Any>(
            "activeLeases" to (cloudLeases + workshopLeases),
            "cloudLeases" to cloudLeases,
            "workshopLeases" to workshopLeases,
        )
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

    private fun startService(context: Context) {
        val (cloudLeases, workshopLeases) = leaseCounts()
        val activeLeaseCount = cloudLeases + workshopLeases
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
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }
    }
}

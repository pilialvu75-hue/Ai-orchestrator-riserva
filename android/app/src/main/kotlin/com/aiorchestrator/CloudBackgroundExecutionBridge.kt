package com.aiorchestrator

import android.content.Context
import android.content.Intent
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Collections

/** Flutter bridge for ref-counted Cloud foreground execution leases. */
object CloudBackgroundExecutionBridge {
    private const val CHANNEL_NAME = "ai_orchestrator/cloud_background_execution"

    private val activeLeaseIds = Collections.synchronizedSet(mutableSetOf<String>())

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
                            val added = activeLeaseIds.add(leaseId)
                            if (added) {
                                startOrRefreshService(app)
                            }
                            result.success(
                                mapOf(
                                    "activeLeases" to activeLeaseIds.size,
                                    "acquired" to added,
                                ),
                            )
                        }

                        "release" -> {
                            val leaseId = requireNotNull(call.argument<String>("leaseId")) {
                                "leaseId is required"
                            }
                            activeLeaseIds.remove(leaseId)
                            if (activeLeaseIds.isEmpty()) {
                                stopService(app)
                            } else {
                                startOrRefreshService(app)
                            }
                            result.success(
                                mapOf("activeLeases" to activeLeaseIds.size),
                            )
                        }

                        "status" -> result.success(
                            mapOf("activeLeases" to activeLeaseIds.size),
                        )

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

    private fun startOrRefreshService(context: Context) {
        val intent = Intent(context, CloudBackgroundExecutionService::class.java).apply {
            action = CloudBackgroundExecutionService.ACTION_START
            putExtra(
                CloudBackgroundExecutionService.EXTRA_ACTIVE_LEASES,
                activeLeaseIds.size,
            )
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }
    }

    private fun stopService(context: Context) {
        val intent = Intent(context, CloudBackgroundExecutionService::class.java).apply {
            action = CloudBackgroundExecutionService.ACTION_STOP
        }
        context.startService(intent)
    }
}

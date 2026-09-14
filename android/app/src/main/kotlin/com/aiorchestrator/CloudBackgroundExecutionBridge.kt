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
                                try {
                                    startService(app)
                                } catch (error: Exception) {
                                    activeLeaseIds.remove(leaseId)
                                    throw error
                                }
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
                                // stopService() is legal from the background and does not
                                // attempt to start a new component after the user has left
                                // the foreground.
                                app.stopService(
                                    Intent(app, CloudBackgroundExecutionService::class.java),
                                )
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

    private fun startService(context: Context) {
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
}

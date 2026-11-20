package com.aiorchestrator

import android.content.Context
import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** A typed, owner-directed QA bridge. Never exposes shell or arbitrary apps. */
object ComputerUseAndroidBridge {
    private const val CHANNEL = "com.aiorchestrator/computer_use_android"

    fun register(context: Context, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getStatus" -> result.success(mapOf(
                        "accessibilityEnabled" to ComputerUseAccessibilityService.isReady(),
                    ))
                    "openAccessibilitySettings" -> {
                        val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        context.startActivity(intent)
                        result.success(null)
                    }
                    "clearTarget" -> {
                        ComputerUseAccessibilityService.clearTarget()
                        result.success(null)
                    }
                    "selectForegroundTarget" -> {
                        ComputerUseAccessibilityService.selectForegroundTarget { ok, code ->
                            if (ok) result.success(code)
                            else result.error(code, "Target not selected", null)
                        }
                    }
                    "tapTarget", "swipeTarget" -> {
                        val x = call.argument<Int>("x")
                        val y = call.argument<Int>("y")
                        val endX = if (call.method == "swipeTarget") call.argument<Int>("endX") else x
                        val endY = if (call.method == "swipeGame") call.argument<Int>("endY") else y
                        if (x == null || y == null || endX == null || endY == null) {
                            result.error("INVALID_COORDINATES", "Coordinates required", null)
                        } else {
                            ComputerUseAccessibilityService.gestureTarget(
                                x, y, endX, endY,
                            ) { ok, code ->
                                if (ok) result.success(code)
                                else result.error(code, "Gesture not performed", null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}

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
                        "targetPackage" to "car.parking.jam.solver.puzzle.games",
                    ))
                    "openAccessibilitySettings" -> {
                        val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        context.startActivity(intent)
                        result.success(null)
                    }
                    "tapGame" -> {
                        val x = call.argument<Int>("x")
                        val y = call.argument<Int>("y")
                        if (x == null || y == null) {
                            result.error("INVALID_COORDINATES", "Coordinates required", null)
                        } else {
                            ComputerUseAccessibilityService.tapGame(x, y) { ok, code ->
                                if (ok) result.success(code)
                                else result.error(code, "Tap not performed", null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}

package com.aiorchestrator

import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.content.pm.PackageManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** A typed, owner-directed QA bridge. Never exposes shell or arbitrary apps. */
object ComputerUseAndroidBridge {
    private const val CHANNEL = "com.aiorchestrator/computer_use_android"

    private val recentVisibleLauncherPackages = mutableSetOf<String>()

    fun register(context: Context, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getStatus" -> result.success(mapOf(
                        "accessibilityEnabled" to ComputerUseAccessibilityService.isReady(),
                    ))
                    "findInstalledApps" -> {
                        val query = call.argument<String>("query")?.trim().orEmpty()
                        if (query.length < 2 || query.length > 80) {
                            result.error("INVALID_QUERY", "Use 2-80 characters", null)
                        } else {
                            val pm = context.packageManager
                            val main = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                            val matches = pm.queryIntentActivities(main, 0)
                                .mapNotNull { resolve ->
                                    val label = resolve.loadLabel(pm).toString()
                                    val pkg = resolve.activityInfo?.packageName ?: return@mapNotNull null
                                    if (pkg == context.packageName || pkg.startsWith("com.android.") ||
                                        pkg.startsWith("com.google.android.permission") ||
                                        pkg == "com.android.settings") return@mapNotNull null
                                    if (label.contains(query, ignoreCase = true) ||
                                        pkg.contains(query, ignoreCase = true)) {
                                        mapOf("label" to label, "package" to pkg)
                                    } else null
                                }
                                .distinctBy { it["package"] }
                                .sortedBy { it["label"]?.lowercase() }
                                .take(15)
                            recentVisibleLauncherPackages.clear()
                            recentVisibleLauncherPackages.addAll(matches.mapNotNull { it["package"] })
                            result.success(matches)
                        }
                    }
                    "launchInstalledApp" -> {
                        val pkg = call.argument<String>("package").orEmpty()
                        if (pkg !in recentVisibleLauncherPackages) {
                            result.error("APP_NOT_SELECTED", "Select a discovered app first", null)
                        } else {
                            recentVisibleLauncherPackages.clear()
                            val intent = context.packageManager.getLaunchIntentForPackage(pkg)
                            if (intent == null) {
                                result.error("APP_NOT_LAUNCHABLE", "Application not launchable", null)
                            } else {
                                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                context.startActivity(intent)
                                result.success(true)
                            }
                        }
                    }
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
                    "typeTargetText" -> {
                        val value = call.argument<String>("text").orEmpty()
                        if (value.isEmpty() || value.length > 512) {
                            result.error("INVALID_TEXT", "Text must be between 1 and 512 characters", null)
                        } else {
                            ComputerUseAccessibilityService.typeInSelectedEditable(value) { ok, code ->
                                if (ok) result.success(code)
                                else result.error(code, "Text was not entered", null)
                            }
                        }
                    }
                    "tapTarget", "swipeTarget" -> {
                        val x = call.argument<Int>("x")
                        val y = call.argument<Int>("y")
                        val endX = if (call.method == "swipeTarget") call.argument<Int>("endX") else x
                        val endY = if (call.method == "swipeTarget") call.argument<Int>("endY") else y
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

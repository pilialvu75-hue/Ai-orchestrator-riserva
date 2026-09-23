package com.aiorchestrator

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter bridge for Android Screen Vision.
 *
 * The bridge never grants projection permission itself. It launches the system
 * MediaProjection consent activity and completes the pending Flutter request
 * only after the foreground service has created a live projection session.
 */
object ScreenVisionBridge {
    private const val CHANNEL_NAME = "com.aiorchestrator/screen_vision"
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingStartResult: MethodChannel.Result? = null

    fun register(context: Context, engine: FlutterEngine) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL_NAME)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestProjection" -> requestProjection(context, result)
                    "captureScreenshot" -> {
                        ScreenVisionForegroundService.capturePng { bytes, error ->
                            mainHandler.post {
                                if (bytes != null) {
                                    result.success(bytes)
                                } else {
                                    result.error(
                                        "SCREEN_VISION_CAPTURE_FAILED",
                                        error ?: "Screen capture failed.",
                                        null,
                                    )
                                }
                            }
                        }
                    }
                    "stopProjection" -> {
                        cancelPendingStart("Screen projection was stopped.")
                        ScreenVisionForegroundService.requestStop(app)
                        result.success(null)
                    }
                    "getStatus" -> result.success(
                        mapOf(
                            "supported" to true,
                            "active" to ScreenVisionForegroundService.isProjectionActive(),
                            "requesting" to hasPendingStart(),
                        ),
                    )
                    else -> result.notImplemented()
                }
            }
    }

    @Synchronized
    private fun requestProjection(context: Context, result: MethodChannel.Result) {
        if (ScreenVisionForegroundService.isProjectionActive()) {
            result.success(true)
            return
        }
        if (pendingStartResult != null) {
            result.error(
                "SCREEN_VISION_BUSY",
                "A MediaProjection consent request is already in progress.",
                null,
            )
            return
        }

        pendingStartResult = result
        try {
            val intent = Intent(context, ScreenVisionPermissionActivity::class.java)
            if (context !is Activity) {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
        } catch (error: Throwable) {
            pendingStartResult = null
            result.error(
                "SCREEN_VISION_PERMISSION_LAUNCH_FAILED",
                error.message ?: "Unable to launch MediaProjection consent.",
                null,
            )
        }
    }

    @Synchronized
    fun completeDenied() {
        val result = pendingStartResult ?: return
        pendingStartResult = null
        mainHandler.post { result.success(false) }
    }

    @Synchronized
    fun completeStarted() {
        val result = pendingStartResult ?: return
        pendingStartResult = null
        mainHandler.post { result.success(true) }
    }

    @Synchronized
    fun completeStartError(message: String) {
        val result = pendingStartResult ?: return
        pendingStartResult = null
        mainHandler.post {
            result.error("SCREEN_VISION_START_FAILED", message, null)
        }
    }

    @Synchronized
    private fun cancelPendingStart(message: String) {
        val result = pendingStartResult ?: return
        pendingStartResult = null
        mainHandler.post {
            result.error("SCREEN_VISION_CANCELLED", message, null)
        }
    }

    @Synchronized
    private fun hasPendingStart(): Boolean = pendingStartResult != null
}

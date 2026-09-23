package com.aiorchestrator

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import java.io.ByteArrayOutputStream

/**
 * App-owned foreground MediaProjection session.
 *
 * The projection exists only after explicit Android system consent. Capture is
 * read-only and remains in memory until Dart persists the returned PNG through
 * the existing multimodal attachment pipeline.
 */
class ScreenVisionForegroundService : Service() {
    companion object {
        private const val ACTION_START = "com.aiorchestrator.screenvision.START"
        private const val ACTION_STOP = "com.aiorchestrator.screenvision.STOP"
        private const val EXTRA_RESULT_CODE = "result_code"
        private const val EXTRA_RESULT_DATA = "result_data"
        private const val NOTIFICATION_CHANNEL = "screen_vision"
        private const val NOTIFICATION_ID = 5892
        private const val CAPTURE_RETRY_MS = 50L
        private const val CAPTURE_MAX_ATTEMPTS = 24

        @Volatile
        private var activeService: ScreenVisionForegroundService? = null

        fun startIntent(context: Context, resultCode: Int, data: Intent): Intent =
            Intent(context, ScreenVisionForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_RESULT_CODE, resultCode)
                putExtra(EXTRA_RESULT_DATA, data)
            }

        fun requestStop(context: Context) {
            val service = activeService ?: return
            service.mainHandler.post { service.stopProjectionAndSelf() }
        }

        fun isProjectionActive(): Boolean =
            activeService?.projectionActive == true

        fun capturePng(callback: (ByteArray?, String?) -> Unit) {
            val service = activeService
            if (service == null || !service.projectionActive) {
                callback(null, "Screen Vision is not active. Request projection first.")
                return
            }
            service.mainHandler.post {
                service.captureWithRetry(0, callback)
            }
        }

        private fun projectionData(intent: Intent): Intent? =
            IntentCompat.getParcelableExtra(
                intent,
                EXTRA_RESULT_DATA,
                Intent::class.java,
            )
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null
    @Volatile
    private var projectionActive = false

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            cleanupProjection(stopProjection = false)
            stopForegroundCompat()
            stopSelf()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopProjectionAndSelf()
                return START_NOT_STICKY
            }
            ACTION_START -> {
                startAsMediaProjectionForeground()
                if (projectionActive) {
                    ScreenVisionBridge.completeStarted()
                    return START_NOT_STICKY
                }

                val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, Int.MIN_VALUE)
                val resultData = projectionData(intent)
                if (resultCode == Int.MIN_VALUE || resultData == null) {
                    ScreenVisionBridge.completeStartError(
                        "MediaProjection consent data is missing.",
                    )
                    stopProjectionAndSelf()
                    return START_NOT_STICKY
                }

                try {
                    startProjection(resultCode, resultData)
                    ScreenVisionBridge.completeStarted()
                } catch (error: Throwable) {
                    ScreenVisionBridge.completeStartError(
                        error.message ?: "Unable to initialize MediaProjection.",
                    )
                    stopProjectionAndSelf()
                }
            }
            else -> stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        cleanupProjection(stopProjection = true)
        if (activeService === this) activeService = null
        super.onDestroy()
    }

    private fun startAsMediaProjectionForeground() {
        createNotificationChannel()
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    PendingIntent.FLAG_IMMUTABLE
                } else {
                    0
                },
        )

        val notification = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL)
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentTitle("AI Orchestrator Screen Vision")
            .setContentText("Screen capture is active")
            .setOngoing(true)
            .setContentIntent(pendingIntent)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                NOTIFICATION_CHANNEL,
                "Screen Vision",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Visible while AI Orchestrator can capture the screen."
            },
        )
    }

    private fun startProjection(resultCode: Int, data: Intent) {
        cleanupProjection(stopProjection = true)

        val metrics = resources.displayMetrics
        val width = metrics.widthPixels.coerceAtLeast(1)
        val height = metrics.heightPixels.coerceAtLeast(1)
        val density = metrics.densityDpi.coerceAtLeast(1)

        val manager =
            getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val newProjection = manager.getMediaProjection(resultCode, data)
            ?: error("Android returned no MediaProjection session.")
        newProjection.registerCallback(projectionCallback, mainHandler)

        val reader = ImageReader.newInstance(
            width,
            height,
            PixelFormat.RGBA_8888,
            2,
        )
        val display = newProjection.createVirtualDisplay(
            "AIOrchestratorScreenVision",
            width,
            height,
            density,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            reader.surface,
            null,
            mainHandler,
        )

        projection = newProjection
        imageReader = reader
        virtualDisplay = display
        projectionActive = true
        activeService = this
    }

    private fun captureWithRetry(
        attempt: Int,
        callback: (ByteArray?, String?) -> Unit,
    ) {
        if (!projectionActive) {
            callback(null, "Screen Vision session stopped before capture.")
            return
        }

        val image = try {
            imageReader?.acquireLatestImage()
        } catch (error: Throwable) {
            callback(null, error.message ?: "Unable to acquire screen image.")
            return
        }

        if (image == null) {
            if (attempt >= CAPTURE_MAX_ATTEMPTS) {
                callback(null, "No screen frame became available.")
            } else {
                mainHandler.postDelayed(
                    { captureWithRetry(attempt + 1, callback) },
                    CAPTURE_RETRY_MS,
                )
            }
            return
        }

        try {
            callback(imageToPng(image), null)
        } catch (error: Throwable) {
            callback(null, error.message ?: "Unable to encode captured screen.")
        } finally {
            image.close()
        }
    }

    private fun imageToPng(image: Image): ByteArray {
        val plane = image.planes.firstOrNull()
            ?: error("Captured screen image has no pixel plane.")
        val buffer = plane.buffer
        val pixelStride = plane.pixelStride
        val rowStride = plane.rowStride
        val rowPadding = rowStride - pixelStride * image.width
        val bitmapWidth = image.width + (rowPadding / pixelStride)

        val padded = Bitmap.createBitmap(
            bitmapWidth,
            image.height,
            Bitmap.Config.ARGB_8888,
        )
        padded.copyPixelsFromBuffer(buffer)

        val cropped = if (bitmapWidth == image.width) {
            padded
        } else {
            Bitmap.createBitmap(padded, 0, 0, image.width, image.height)
        }

        return try {
            ByteArrayOutputStream().use { output ->
                if (!cropped.compress(Bitmap.CompressFormat.PNG, 100, output)) {
                    error("PNG compression failed.")
                }
                output.toByteArray()
            }
        } finally {
            if (cropped !== padded) cropped.recycle()
            padded.recycle()
        }
    }

    private fun stopProjectionAndSelf() {
        cleanupProjection(stopProjection = true)
        stopForegroundCompat()
        stopSelf()
    }

    private fun cleanupProjection(stopProjection: Boolean) {
        projectionActive = false
        virtualDisplay?.release()
        virtualDisplay = null
        imageReader?.close()
        imageReader = null

        val existingProjection = projection
        projection = null
        if (stopProjection) {
            try {
                existingProjection?.stop()
            } catch (_: Throwable) {
                // The system may already have revoked the projection.
            }
        }
        if (activeService === this) activeService = null
    }

    private fun stopForegroundCompat() {
        ServiceCompat.stopForeground(
            this,
            ServiceCompat.STOP_FOREGROUND_REMOVE,
        )
    }
}

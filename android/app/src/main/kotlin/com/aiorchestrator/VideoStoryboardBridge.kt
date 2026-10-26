package com.aiorchestrator

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.math.roundToInt

/**
 * Android-only video frame sampler for an explicitly selected local video.
 *
 * Returns a JPEG contact sheet of three sampled frames. Audio is NOT decoded
 * or transmitted. Sampling happens off the Flutter/UI thread; the original
 * user video file is never changed.
 */
object VideoStoryboardBridge {
    private const val CHANNEL = "com.aiorchestrator/video_storyboard"
    private const val MAX_DURATION_MS = 10 * 60 * 1000L
    private const val MAX_INPUT_BYTES = 100 * 1024 * 1024L
    private const val MAX_OUTPUT_BYTES = 8 * 1024 * 1024
    private const val FRAME_WIDTH = 320
    private const val FRAME_HEIGHT = 260
    private val mainHandler = Handler(Looper.getMainLooper())

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "extractStoryboard") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")?.trim().orEmpty()
                if (path.isEmpty()) {
                    result.error("VIDEO_INVALID_PATH", "No video selected.", null)
                    return@setMethodCallHandler
                }

                Thread {
                    try {
                        val source = File(path)
                        if (!source.isFile || !source.canRead() ||
                            source.length() <= 0 ||
                            source.length() > MAX_INPUT_BYTES
                        ) {
                            error("Invalid or oversized source.")
                        }
                        val jpeg = makeStoryboard(path)
                        mainHandler.post { result.success(jpeg) }
                    } catch (_: Throwable) {
                        // Never send file paths or the codec exception to Dart
                        // diagnostics: a private video path can identify a user.
                        mainHandler.post {
                            result.error(
                                "VIDEO_FRAME_DECODE_FAILED",
                                "Unable to read this video. Use a short MP4.",
                                null,
                            )
                        }
                    }
                }.start()
            }
    }

    private fun makeStoryboard(path: String): ByteArray {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            val duration = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull()
                ?: error("Video duration unknown.")
            require(duration > 0 && duration <= MAX_DURATION_MS)

            val sheet = Bitmap.createBitmap(
                FRAME_WIDTH * 3, FRAME_HEIGHT, Bitmap.Config.RGB_565,
            )
            try {
                val canvas = Canvas(sheet)
                canvas.drawColor(Color.BLACK)
                val times = listOf(0.15, 0.50, 0.85)
                times.forEachIndexed { index, fraction ->
                    val atUs = (duration.toDouble() * fraction * 1000.0)
                        .roundToInt().toLong()
                    val frame = retriever.getFrameAtTime(
                        atUs,
                        MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                    ) ?: error("Frame not available.")
                    try {
                        val scale = minOf(
                            FRAME_WIDTH.toFloat() / frame.width,
                            FRAME_HEIGHT.toFloat() / frame.height,
                        )
                        val width = (frame.width * scale).roundToInt().coerceAtLeast(1)
                        val height = (frame.height * scale).roundToInt().coerceAtLeast(1)
                        val scaled = Bitmap.createScaledBitmap(frame, width, height, true)
                        try {
                            val left = index * FRAME_WIDTH + (FRAME_WIDTH - width) / 2f
                            val top = (FRAME_HEIGHT - height) / 2f
                            canvas.drawBitmap(scaled, left, top, null)
                        } finally {
                            if (scaled !== frame) scaled.recycle()
                        }
                    } finally {
                        frame.recycle()
                    }
                }
                ByteArrayOutputStream().use { stream ->
                    require(sheet.compress(Bitmap.CompressFormat.JPEG, 82, stream))
                    val bytes = stream.toByteArray()
                    require(bytes.isNotEmpty() && bytes.size <= MAX_OUTPUT_BYTES)
                    return bytes
                }
            } finally {
                sheet.recycle()
            }
        } finally {
            retriever.release()
        }
    }
}

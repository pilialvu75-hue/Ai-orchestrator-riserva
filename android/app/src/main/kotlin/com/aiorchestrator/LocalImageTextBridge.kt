package com.aiorchestrator

import android.app.ActivityManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Latin-script OCR on the device using the bundled ML Kit model.
 *
 * Kept on a distinct channel from the Library's image category plugin.
 * Never logs or transmits the photo, path, OCR output or user prompt.
 * Only one OCR job is allowed; downsampling and Android low-memory checks
 * prevent a large image from destabilizing the resident text model.
 */
internal object LocalImageTextBridge {
    private const val channelName = "com.aiorchestrator/local_image_text"
    private const val maxInputBytes = 8L * 1024 * 1024
    private const val maxImageEdge = 1600
    private const val maxOutputChars = 1800
    private val active = AtomicBoolean(false)
    private val executor = Executors.newSingleThreadExecutor()
    private val mainThread = Handler(Looper.getMainLooper())

    fun register(context: Context, engine: FlutterEngine) {
        val applicationContext = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method != "readText") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                if (path.isNullOrBlank()) {
                    result.error("OCR_INVALID_IMAGE", "Immagine non selezionata.", null)
                    return@setMethodCallHandler
                }
                if (!active.compareAndSet(false, true)) {
                    result.error("OCR_BUSY", "Lettura testo locale già in corso.", null)
                    return@setMethodCallHandler
                }

                executor.execute {
                    try {
                        val file = File(path)
                        if (!file.isFile || !file.canRead() ||
                            file.length() !in 1L..maxInputBytes) {
                            mainThread.post {
                                active.set(false)
                                result.error("OCR_INVALID_IMAGE",
                                    "Immagine assente o superiore a 8 MB.", null)
                            }
                            return@execute
                        }
                        val activityManager = applicationContext.getSystemService(
                            Context.ACTIVITY_SERVICE
                        ) as? ActivityManager
                        val memory = ActivityManager.MemoryInfo()
                        activityManager?.getMemoryInfo(memory)
                        if (activityManager != null &&
                            (memory.lowMemory || memory.availMem < 320L * 1024 * 1024)) {
                            mainThread.post {
                                active.set(false)
                                result.error(
                                    "OCR_MEMORY",
                                    "Memoria disponibile insufficiente per leggere il testo.",
                                    null
                                )
                            }
                            return@execute
                        }

                        val bounds = BitmapFactory.Options().apply {
                            inJustDecodeBounds = true
                        }
                        BitmapFactory.decodeFile(file.path, bounds)
                        val width = bounds.outWidth
                        val height = bounds.outHeight
                        if (width <= 0 || height <= 0 ||
                            width > 16384 || height > 16384) {
                            mainThread.post {
                                active.set(false)
                                result.error("OCR_INVALID_IMAGE",
                                    "Dimensioni immagine non supportate.", null)
                            }
                            return@execute
                        }
                        var sampleSize = 1
                        while (width / sampleSize > maxImageEdge ||
                            height / sampleSize > maxImageEdge) {
                            sampleSize *= 2
                        }
                        val options = BitmapFactory.Options().apply {
                            inSampleSize = sampleSize
                            inPreferredConfig = Bitmap.Config.RGB_565
                        }
                        val bitmap = BitmapFactory.decodeFile(file.path, options)
                            ?: throw IllegalArgumentException("decode failed")

                        mainThread.post {
                            val recognizer = TextRecognition.getClient(
                                TextRecognizerOptions.DEFAULT_OPTIONS
                            )
                            try {
                                recognizer.process(InputImage.fromBitmap(bitmap, 0))
                                    .addOnSuccessListener { detected ->
                                        val text = detected.text.trim()
                                        result.success(mapOf(
                                            "text" to text.take(maxOutputChars),
                                            "truncated" to (text.length > maxOutputChars)
                                        ))
                                    }
                                    .addOnFailureListener {
                                        result.error("OCR_FAILED",
                                            "Impossibile leggere il testo della foto.", null)
                                    }
                                    .addOnCompleteListener {
                                        recognizer.close()
                                        bitmap.recycle()
                                        active.set(false)
                                    }
                            } catch (_: Exception) {
                                recognizer.close()
                                bitmap.recycle()
                                active.set(false)
                                result.error("OCR_FAILED",
                                    "Impossibile leggere il testo della foto.", null)
                            }
                        }
                    } catch (_: OutOfMemoryError) {
                        mainThread.post {
                            active.set(false)
                            result.error("OCR_MEMORY",
                                "Memoria insufficiente durante la lettura.", null)
                        }
                    } catch (_: Exception) {
                        mainThread.post {
                            active.set(false)
                            result.error("OCR_FAILED",
                                "Impossibile preparare l'immagine per OCR.", null)
                        }
                    }
                }
            }
    }
}

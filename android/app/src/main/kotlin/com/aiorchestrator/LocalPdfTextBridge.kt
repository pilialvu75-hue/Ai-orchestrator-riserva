package com.aiorchestrator

import android.app.ActivityManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.pdf.PdfRenderer
import android.os.Build
import android.os.ParcelFileDescriptor
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Android-only PDF text reader: uses platform text on API >= 35,
 * and bundled on-device ML Kit OCR for pages without selectable text.
 *
 * Never uploads or logs PDF bytes, paths, OCR output, or user prompts.
 * Each page is opened/closed serially, with strict file/page/RAM bounds.
 */
internal object LocalPdfTextBridge {
    private const val channelName = "com.aiorchestrator/local_pdf_text"
    private const val maxFileBytes = 8L * 1024 * 1024
    private const val maxPages = 6
    private const val maxOutputChars = 16000
    private const val maxBitmapEdge = 1500
    private val active = AtomicBoolean(false)
    private val executor = Executors.newSingleThreadExecutor()

    fun register(context: Context, engine: FlutterEngine) {
        val applicationContext = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method != "extractText") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                if (path.isNullOrBlank()) {
                    result.error("PDF_INVALID", "PDF non selezionato.", null)
                    return@setMethodCallHandler
                }
                if (!active.compareAndSet(false, true)) {
                    result.error("PDF_BUSY", "Lettura PDF già in corso.", null)
                    return@setMethodCallHandler
                }
                executor.execute {
                    var code: String? = null
                    var message: String? = null
                    var response: Map<String, Any>? = null
                    try {
                        val file = File(path)
                        if (!file.isFile || !file.canRead() ||
                            file.length() !in 5L..maxFileBytes) {
                            throw PdfReadError("PDF_INVALID", "PDF assente, vuoto o oltre 8 MB.")
                        }
                        val header = ByteArray(5)
                        FileInputStream(file).use { input ->
                            if (input.read(header) != 5 ||
                                String(header, Charsets.US_ASCII) != "%PDF-") {
                                throw PdfReadError("PDF_INVALID", "Il file selezionato non è un PDF valido.")
                            }
                        }
                        val manager = applicationContext.getSystemService(
                            Context.ACTIVITY_SERVICE
                        ) as? ActivityManager
                        val memory = ActivityManager.MemoryInfo()
                        manager?.getMemoryInfo(memory)
                        if (manager != null &&
                            (memory.lowMemory || memory.availMem < 384L * 1024 * 1024)) {
                            throw PdfReadError(
                                "PDF_MEMORY", "Memoria insufficiente per leggere il PDF."
                            )
                        }

                        val output = StringBuilder()
                        var textPages = 0
                        var ocrPages = 0
                        var totalPages = 0
                        ParcelFileDescriptor.open(
                            file, ParcelFileDescriptor.MODE_READ_ONLY
                        ).use { descriptor ->
                            PdfRenderer(descriptor).use { renderer ->
                                totalPages = renderer.pageCount
                                if (totalPages !in 1..maxPages) {
                                    throw PdfReadError(
                                        "PDF_PAGES",
                                        "PDF fino a $maxPages pagine; trovato: $totalPages."
                                    )
                                }
                                for (pageIndex in 0 until totalPages) {
                                    val pageText: String
                                    var pageViaOcr = false
                                    renderer.openPage(pageIndex).use { page ->
                                        val selectable = if (Build.VERSION.SDK_INT >= 35) {
                                            page.textContents.joinToString("\n") { it.text }.trim()
                                        } else {
                                            ""
                                        }
                                        if (selectable.isNotBlank()) {
                                            pageText = selectable
                                        } else {
                                            pageViaOcr = true
                                            val widthPoints = page.width
                                            val heightPoints = page.height
                                            if (widthPoints <= 0 || heightPoints <= 0 ||
                                                widthPoints > 16384 || heightPoints > 16384) {
                                                throw PdfReadError(
                                                    "PDF_INVALID", "Dimensioni pagina non supportate."
                                                )
                                            }
                                            val scale = min(
                                                2.0, min(
                                                    maxBitmapEdge.toDouble() / widthPoints,
                                                    maxBitmapEdge.toDouble() / heightPoints
                                                )
                                            )
                                            val width = (widthPoints * scale).roundToInt().coerceAtLeast(1)
                                            val height = (heightPoints * scale).roundToInt().coerceAtLeast(1)
                                            val bitmap = Bitmap.createBitmap(
                                                width, height, Bitmap.Config.ARGB_8888
                                            )
                                            try {
                                                bitmap.eraseColor(Color.WHITE)
                                                val matrix = Matrix().apply {
                                                    setScale(scale.toFloat(), scale.toFloat())
                                                }
                                                page.render(
                                                    bitmap, null, matrix,
                                                    PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY
                                                )
                                                val recognizer = TextRecognition.getClient(
                                                    TextRecognizerOptions.DEFAULT_OPTIONS
                                                )
                                                try {
                                                    val detected = Tasks.await(
                                                        recognizer.process(
                                                            InputImage.fromBitmap(bitmap, 0)
                                                        ), 12, TimeUnit.SECONDS
                                                    )
                                                    pageText = detected.text.trim()
                                                } finally {
                                                    recognizer.close()
                                                }
                                            } finally {
                                                bitmap.recycle()
                                            }
                                        }
                                    }
                                    if (pageViaOcr) ocrPages++ else textPages++
                                    if (pageText.isNotBlank()) {
                                        val chunk = "\n[Pagina ${pageIndex + 1}/$totalPages]\n$pageText"
                                        if (output.length + chunk.length > maxOutputChars) {
                                            throw PdfReadError(
                                                "PDF_TOO_LONG",
                                                "Testo PDF troppo lungo; massimo $maxOutputChars caratteri."
                                            )
                                        }
                                        output.append(chunk)
                                    }
                                }
                            }
                        }
                        if (output.isBlank()) {
                            throw PdfReadError(
                                "PDF_NO_TEXT", "Nessuna scritta leggibile nelle pagine del PDF."
                            )
                        }
                        response = mapOf(
                            "text" to output.toString().trim(),
                            "pages" to totalPages,
                            "textPages" to textPages,
                            "ocrPages" to ocrPages
                        )
                    } catch (error: PdfReadError) {
                        code = error.reason
                        message = error.message
                    } catch (_: OutOfMemoryError) {
                        code = "PDF_MEMORY"
                        message = "Memoria insufficiente per leggere il PDF."
                    } catch (_: Exception) {
                        code = "PDF_FAILED"
                        message = "Impossibile leggere questo PDF (formato o protezione non supportati)."
                    } finally {
                        active.set(false)
                    }
                    android.os.Handler(android.os.Looper.getMainLooper()).post {
                        val data = response
                        if (data != null) {
                            result.success(data)
                        } else {
                            result.error(code ?: "PDF_FAILED", message ?: "Lettura fallita.", null)
                        }
                    }
                }
            }
    }

    private class PdfReadError(
        val reason: String, override val message: String
    ) : Exception(message)
}

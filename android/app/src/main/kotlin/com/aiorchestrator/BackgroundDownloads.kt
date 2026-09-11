package com.aiorchestrator

import android.app.DownloadManager
import android.content.Context
import android.net.Uri
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

/** The system owns the transfer; destroying Flutter must never cancel it. */
object BackgroundDownloads {
    fun register(context: Context, engine: FlutterEngine) {
        val app = context.applicationContext
        val manager = app.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        val prefs = app.getSharedPreferences("background_downloads_v1", Context.MODE_PRIVATE)
        val directory = app.getExternalFilesDir("background_downloads")
        MethodChannel(engine.dartExecutor.binaryMessenger, "ai_orchestrator/background_downloads")
            .setMethodCallHandler { call, result ->
                try {
                    val url = requireNotNull(call.argument<String>("url"))
                    val uri = Uri.parse(url)
                    require(uri.scheme == "https" || uri.scheme == "http")
                    require(!uri.host.isNullOrEmpty())
                    val key = MessageDigest.getInstance("SHA-256")
                        .digest(url.toByteArray(Charsets.UTF_8))
                        .joinToString("") { "%02x".format(it) }
                    val root = requireNotNull(directory) { "External app storage unavailable" }
                    val file = File(root, "$key.download")
                    var id = prefs.getLong(key, -1)
                    fun snapshot(): Map<String, Any>? {
                        if (id < 0) return null
                        manager.query(DownloadManager.Query().setFilterById(id))?.use { cursor ->
                            if (!cursor.moveToFirst()) return null
                            fun number(column: String) = cursor.getLong(cursor.getColumnIndexOrThrow(column))
                            return mapOf(
                                "status" to number(DownloadManager.COLUMN_STATUS),
                                "reason" to number(DownloadManager.COLUMN_REASON),
                                "received" to number(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR),
                                "total" to number(DownloadManager.COLUMN_TOTAL_SIZE_BYTES),
                                "path" to file.absolutePath
                            )
                        }
                        return null
                    }
                    when (call.method) {
                        "start" -> {
                            val previous = snapshot()
                            if (previous == null || previous["status"] == DownloadManager.STATUS_FAILED.toLong() ||
                                (previous["status"] == DownloadManager.STATUS_SUCCESSFUL.toLong() && !file.isFile)) {
                                if (id >= 0) manager.remove(id)
                                root.mkdirs()
                                if (file.exists()) check(file.delete()) { "Cannot replace download" }
                                val request = DownloadManager.Request(uri)
                                    .setTitle(call.argument<String>("title") ?: "AI Orchestrator")
                                    .setDescription("Download in background · riapri l’app per completare la preparazione")
                                    .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                                    .setDestinationInExternalFilesDir(app, "background_downloads", file.name)
                                    .setAllowedOverMetered(true)
                                    .setAllowedOverRoaming(false)
                                    .addRequestHeader("Accept-Encoding", "identity")
                                id = manager.enqueue(request)
                                if (!prefs.edit().putLong(key, id).commit()) {
                                    manager.remove(id)
                                    error("Cannot persist download")
                                }
                            }
                            result.success(snapshot())
                        }
                        "status" -> result.success(snapshot())
                        "cancel", "release" -> {
                            if (id >= 0) manager.remove(id)
                            file.delete()
                            prefs.edit().remove(key).commit()
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("BACKGROUND_DOWNLOAD", error.message, null)
                }
            }
    }
}

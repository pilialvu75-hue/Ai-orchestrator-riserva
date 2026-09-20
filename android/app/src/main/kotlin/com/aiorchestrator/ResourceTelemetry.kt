package com.aiorchestrator

import android.app.ActivityManager
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.res.Configuration
import android.os.Debug
import android.os.SystemClock
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Read-only, bounded samples. No vendor sysfs probing or GPU estimates. */
class ResourceTelemetry(private val context: Context, engine: FlutterEngine) : ComponentCallbacks2 {
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "com.aiorchestrator/resources")
    private var trimLevel = 0
    private var trimAt = 0L

    init {
        context.registerComponentCallbacks(this)
        channel.setMethodCallHandler { call, result ->
            if (call.method != "sample") {
                result.notImplemented()
            } else {
                try {
                    val info = ActivityManager.MemoryInfo()
                    (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(info)
                    // /proc/self/status is cheap and scoped to our own process.
                    val rssKb = File("/proc/self/status").useLines { lines ->
                        lines.firstOrNull { it.startsWith("VmRSS:") }
                            ?.trim()?.split(Regex("\\s+"))?.getOrNull(1)?.toLongOrNull()
                    }
                    result.success(mapOf(
                        "availableBytes" to info.availMem,
                        "totalBytes" to info.totalMem,
                        "thresholdBytes" to info.threshold,
                        "lowMemory" to info.lowMemory,
                        "rssBytes" to rssKb?.times(1024),
                        "nativeHeapBytes" to Debug.getNativeHeapAllocatedSize(),
                        "trimLevel" to if (SystemClock.elapsedRealtime() - trimAt < 10000) trimLevel else 0
                    ))
                } catch (_: Exception) {
                    result.error("unavailable", "Resource sample unavailable", null)
                }
            }
        }
    }

    override fun onTrimMemory(level: Int) {
        trimLevel = level
        trimAt = SystemClock.elapsedRealtime()
    }
    override fun onLowMemory() { onTrimMemory(ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL) }
    override fun onConfigurationChanged(configuration: Configuration) {}
    fun close() {
        channel.setMethodCallHandler(null)
        context.unregisterComponentCallbacks(this)
    }
}

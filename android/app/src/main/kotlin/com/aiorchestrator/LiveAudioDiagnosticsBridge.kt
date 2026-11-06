package com.aiorchestrator

import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Audio capability diagnostics only. Does not create an audio effect, attach
 * to a recorder session, or certify that echo cancellation is functioning.
 */
object LiveAudioDiagnosticsBridge {
    private const val CHANNEL = "com.aiorchestrator/live_audio_diagnostics"

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getCapabilities" -> result.success(
                        mapOf(
                            "aecAvailable" to AcousticEchoCanceler.isAvailable(),
                            "noiseSuppressorAvailable" to NoiseSuppressor.isAvailable(),
                            // Must remain false until an actual capture-session
                            // effect and a verified playback-reference test exist.
                            "aecAttached" to false,
                            "echoSuppressionVerified" to false,
                            "automaticBargeInEnabled" to false
                        )
                    )
                    else -> result.notImplemented()
                }
            }
    }
}

package com.aiorchestrator

import android.content.Context
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/**
 * Android system TTS adapter. It does not load a model inside AIVEXUS and
 * never touches the application's Sherpa ASR or llama runtime.
 */
class AndroidSystemTtsBridge(
    private val context: Context,
    engine: FlutterEngine,
) {
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "com.aiorchestrator/system_tts")
    private var tts: TextToSpeech? = null
    private var ready = false
    private var initializing = false
    private val pending = mutableMapOf<String, MethodChannel.Result>()
    private var generation = 0L

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "inspect" -> ensureReady { ok ->
                    if (!ok) { result.success(mapOf("ready" to false, "voices" to emptyList<Map<String, String>>())); return@ensureReady }
                    val voices = tts?.voices.orEmpty()
                        .filter { !it.isNetworkConnectionRequired }
                        .map { mapOf("name" to it.name, "language" to it.locale.toLanguageTag()) }
                        .sortedBy { it["language"] }
                    result.success(mapOf("ready" to true, "voices" to voices))
                }
                "speak" -> {
                    val text = call.argument<String>("text").orEmpty()
                    val language = call.argument<String>("language").orEmpty()
                    if (text.isBlank()) { result.success(false); return@setMethodCallHandler }
                    ensureReady { ok ->
                        if (!ok) { result.error("TTS_UNAVAILABLE", "Android TTS engine unavailable", null); return@ensureReady }
                        val engineTts = tts ?: run { result.error("TTS_UNAVAILABLE", "Android TTS engine unavailable", null); return@ensureReady }
                        val locale = Locale.forLanguageTag(language.ifBlank { "it" })
                        val selected = engineTts.voices?.firstOrNull { !it.isNetworkConnectionRequired && it.locale.language == locale.language }
                        if (selected == null) {
                            result.error("OFFLINE_VOICE_MISSING", "No offline Android voice for $language", null)
                            return@ensureReady
                        }
                        clearPending()
                        engineTts.stop()
                        engineTts.voice = selected
                        generation++
                        val id = "aivexus-${generation}"
                        pending[id] = result
                        val code = engineTts.speak(text, TextToSpeech.QUEUE_FLUSH, null, id)
                        if (code == TextToSpeech.ERROR) {
                            pending.remove(id)
                            result.error("TTS_PLAYBACK", "Android speech could not start", null)
                        }
                    }
                }
                "stop" -> { clearPending(); tts?.stop(); result.success(true) }
                else -> result.notImplemented()
            }
        }
    }

    private fun clearPending() {
        val previous = pending.values.toList()
        pending.clear()
        previous.forEach { it.success(false) }
    }

    private fun ensureReady(callback: (Boolean) -> Unit) {
        if (ready) { callback(true); return }
        if (initializing) { callback(false); return }
        initializing = true
        tts = TextToSpeech(context.applicationContext) { code ->
            initializing = false
            ready = code == TextToSpeech.SUCCESS
            tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) {}
                override fun onDone(utteranceId: String?) = complete(utteranceId, true)
                @Deprecated("Deprecated Android callback")
                override fun onError(utteranceId: String?) = complete(utteranceId, false)
                override fun onError(utteranceId: String?, errorCode: Int) = complete(utteranceId, false)
            })
            callback(ready)
        }
    }

    private fun complete(id: String?, ok: Boolean) {
        if (id == null) return
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            pending.remove(id)?.success(ok)
        }
    }

    fun close() {
        clearPending()
        channel.setMethodCallHandler(null)
        tts?.stop()
        tts?.shutdown()
        tts = null
        ready = false
    }
}

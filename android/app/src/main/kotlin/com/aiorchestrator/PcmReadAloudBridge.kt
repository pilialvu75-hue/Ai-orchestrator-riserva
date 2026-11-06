package com.aiorchestrator

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.Executors

/**
 * Offline PCM read-aloud transport.
 *
 * Unlike mp_audio_stream, this player retains generated PCM on app-private
 * disk so that pause/resume and +/-10s seek do not regenerate the text.
 * Playback position comes from AudioTrack's played-frame clock, NOT a timer.
 *
 * This class is NOT an Android MediaSession/foreground playback service.
 * Lock-screen controls and guaranteed cross-app playback remain issue #967.
 */
internal class PcmReadAloudBridge(private val context: Context) {
    private val lock = Any()
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private val path = File(context.cacheDir, "read_aloud_current.pcm")
    private var reader: RandomAccessFile? = null
    private var writer: RandomAccessFile? = null
    private var track: AudioTrack? = null
    private var sampleRate = 0
    private var totalFrames = 0L
    // Bound private cache use on storage-constrained Android devices.
    private val maxCacheBytes = 96L * 1024L * 1024L
    private var playCursor = 0L
    private var seekBase = 0L
    private var paused = false
    private var finished = false
    private var active = false
    @Volatile private var alive = true

    init {
        Thread({ pump() }, "aivexus-tts-pcm").apply {
            isDaemon = true
            start()
        }
    }

    private fun playedFrames(): Long {
        val clock = track?.playbackHeadPosition?.toLong() ?: 0L
        return (seekBase + (clock and 0xffffffffL)).coerceIn(0L, totalFrames)
    }

    private fun snapshot(): Map<String, Any> = synchronized(lock) {
        val position = playedFrames()
        val atEnd = finished && position >= totalFrames
        mapOf(
            "supported" to true,
            "active" to active,
            "paused" to paused,
            "playing" to (active && !paused && totalFrames > position && !atEnd),
            "positionMs" to if (sampleRate > 0) position * 1000L / sampleRate else 0L,
            "bufferedMs" to if (sampleRate > 0) totalFrames * 1000L / sampleRate else 0L,
            "complete" to finished
        )
    }

    private fun releaseLocked() {
        active = false
        try { track?.pause() } catch (_: Exception) {}
        try { track?.flush() } catch (_: Exception) {}
        try { track?.release() } catch (_: Exception) {}
        track = null
        try { reader?.close() } catch (_: Exception) {}
        try { writer?.close() } catch (_: Exception) {}
        reader = null
        writer = null
        sampleRate = 0
        totalFrames = 0
        playCursor = 0
        seekBase = 0
        finished = false
        paused = false
        if (path.exists()) path.delete()
    }

    private fun prepare() = synchronized(lock) {
        releaseLocked()
        path.parentFile?.mkdirs()
        writer = RandomAccessFile(path, "rw")
        reader = RandomAccessFile(path, "r")
        active = true
    }

    private fun append(pcm: ByteArray, rate: Int) = synchronized(lock) {
        require(active) { "PCM session is not prepared" }
        require(rate in 8000..48000) { "Unsupported PCM sample rate" }
        require(pcm.isNotEmpty() && pcm.size % 2 == 0) { "Invalid PCM16 chunk" }
        if (sampleRate == 0) {
            sampleRate = rate
            val minBuffer = AudioTrack.getMinBufferSize(
                rate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT
            )
            require(minBuffer > 0) { "AudioTrack reports unsupported format" }
            val bufferSize = maxOf(minBuffer, rate * 2) // one second at PCM16 mono
            track = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(rate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build()
                )
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(bufferSize)
                .build()
            check(track?.state == AudioTrack.STATE_INITIALIZED) {
                "Failed to initialize PCM AudioTrack"
            }
            track?.play()
        } else {
            require(rate == sampleRate) { "PCM rate changed within one read-aloud session" }
        }
        require(totalFrames * 2L + pcm.size <= maxCacheBytes) {
            "Read-aloud exceeds the 96 MiB cached PCM safety limit"
        }
        val file = writer ?: error("PCM writer is unavailable")
        file.seek(totalFrames * 2L)
        file.write(pcm)
        totalFrames += pcm.size / 2L
    }

    private fun pause() = synchronized(lock) {
        if (active && !paused) {
            paused = true
            track?.pause()
        }
    }

    private fun resume() = synchronized(lock) {
        if (active && paused) {
            paused = false
            track?.play()
        }
    }

    private fun seek(targetMs: Long, relative: Boolean) = synchronized(lock) {
        if (!active || sampleRate == 0) return@synchronized
        val absoluteMs = if (relative) {
            playedFrames() * 1000L / sampleRate + targetMs
        } else {
            targetMs
        }
        val desired = (absoluteMs.coerceAtLeast(0L) * sampleRate / 1000L)
            .coerceIn(0L, totalFrames)
        val currentTrack = track ?: return@synchronized
        currentTrack.pause()
        currentTrack.flush()
        currentTrack.stop()
        seekBase = desired
        playCursor = desired
        // AudioTrack playback clock resets on stop/flush.
        if (!paused && (!finished || desired < totalFrames)) {
            currentTrack.play()
        }
    }

    private fun pump() {
        while (alive) {
            try {
                var hadWork = false
                synchronized(lock) {
                    val currentTrack = track
                    val currentReader = reader
                    if (active && !paused && currentTrack != null &&
                        currentReader != null && sampleRate > 0
                    ) {
                        val bufferedInTrack = playCursor - playedFrames()
                        val available = totalFrames - playCursor
                        if (bufferedInTrack < sampleRate && available > 0) {
                            val frames = minOf(4096L, available).toInt()
                            val data = ByteArray(frames * 2)
                            currentReader.seek(playCursor * 2L)
                            currentReader.readFully(data)
                            val sent = currentTrack.write(
                                data, 0, data.size, AudioTrack.WRITE_NON_BLOCKING
                            )
                            if (sent > 0) {
                                playCursor += sent / 2L
                                hadWork = true
                            }
                        }
                    }
                }
                Thread.sleep(if (hadWork) 12 else 40)
            } catch (_: InterruptedException) {
                break
            } catch (_: Exception) {
                // Keep the engine responsive; the next status/stop is still usable.
                Thread.sleep(30)
            }
        }
    }

    fun close() {
        synchronized(lock) {
            alive = false
            releaseLocked()
        }
        io.shutdown()
    }

    companion object {
        private const val CHANNEL = "com.aiorchestrator/tts_pcm_transport"

        fun register(context: Context, engine: FlutterEngine): PcmReadAloudBridge {
            val transport = PcmReadAloudBridge(context.applicationContext)
            MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
                .setMethodCallHandler { call, result ->
                    try {
                        when (call.method) {
                            "prepare" -> {
                                synchronized(transport.lock) { transport.prepare() }
                                result.success(null)
                            }
                            "append" -> {
                                val pcm = call.argument<ByteArray>("pcm")
                                    ?: throw IllegalArgumentException("Missing PCM chunk")
                                val rate = call.argument<Int>("sampleRate")
                                    ?: throw IllegalArgumentException("Missing sample rate")
                                transport.io.execute {
                                    try {
                                        transport.append(pcm, rate)
                                        transport.main.post { result.success(null) }
                                    } catch (error: Exception) {
                                        transport.main.post {
                                            result.error("PCM_APPEND", error.message, null)
                                        }
                                    }
                                }
                            }
                            "finish" -> {
                                synchronized(transport.lock) { transport.finished = true }
                                result.success(null)
                            }
                            "pause" -> {
                                transport.pause()
                                result.success(transport.snapshot())
                            }
                            "resume" -> {
                                transport.resume()
                                result.success(transport.snapshot())
                            }
                            "seek" -> {
                                transport.seek(
                                    (call.argument<Number>("milliseconds")?.toLong() ?: 0L),
                                    false
                                )
                                result.success(transport.snapshot())
                            }
                            "seekRelative" -> {
                                transport.seek(
                                    (call.argument<Number>("milliseconds")?.toLong() ?: 0L),
                                    true
                                )
                                result.success(transport.snapshot())
                            }
                            "status" -> result.success(transport.snapshot())
                            "stop" -> {
                                synchronized(transport.lock) { transport.releaseLocked() }
                                result.success(null)
                            }
                            "dispose" -> {
                                transport.close()
                                result.success(null)
                            }
                            else -> result.notImplemented()
                        }
                    } catch (error: Exception) {
                        result.error("PCM_TRANSPORT", error.message, null)
                    }
                }
            return transport
        }
    }
}

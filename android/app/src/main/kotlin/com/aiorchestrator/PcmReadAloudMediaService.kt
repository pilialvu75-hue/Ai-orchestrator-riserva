package com.aiorchestrator

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.content.ContextCompat

/**
 * Foreground owner of the offline, bounded PCM read-aloud timeline.
 *
 * Starts ONLY when the user taps read-aloud in the visible app (through the
 * bridge's prepare command). Android 17 forbids starting background audio from
 * a hidden Activity without a foreground service with user-initiated WIU.
 * The PCM player and the MediaSession are owned here, never by MainActivity.
 *
 * Uses the Android framework MediaSession and native AudioTrack to avoid
 * replacing the working offline Kokoro/TTS/STT stack with ExoPlayer.
 */
internal class PcmReadAloudMediaService : Service() {
    companion object {
        private const val CHANNEL = "aivexus_read_aloud"
        private const val NOTIFICATION_ID = 6617

        const val ACTION_START = "com.aiorchestrator.audio.START"
        private const val ACTION_PAUSE = "com.aiorchestrator.audio.PAUSE"
        private const val ACTION_PLAY = "com.aiorchestrator.audio.PLAY"
        private const val ACTION_REWIND = "com.aiorchestrator.audio.REWIND"
        private const val ACTION_FORWARD = "com.aiorchestrator.audio.FORWARD"
        private const val ACTION_STOP = "com.aiorchestrator.audio.STOP"

        @Volatile private var current: PcmReadAloudMediaService? = null
        private val waiting = mutableListOf<(PcmReadAloudMediaService?, String?) -> Unit>()

        /** Must run on the main thread. The callback fires AFTER startForeground. */
        fun ensureStarted(
            context: Context,
            callback: (PcmReadAloudMediaService?, String?) -> Unit
        ) {
            val active = current
            if (active != null && active.foregroundReady) {
                callback(active, null)
                return
            }
            waiting.add(callback)
            try {
                val intent = Intent(context, PcmReadAloudMediaService::class.java)
                    .setAction(ACTION_START)
                ContextCompat.startForegroundService(context, intent)
            } catch (error: Exception) {
                val pending = waiting.toList()
                waiting.clear()
                for (reply in pending) reply(null, error.message ?: "Audio service start failed")
            }
        }

        fun active(): PcmReadAloudMediaService? = current?.takeIf { it.foregroundReady }

        private fun completeStartup(service: PcmReadAloudMediaService?, error: String?) {
            val pending = waiting.toList()
            waiting.clear()
            for (reply in pending) reply(service, error)
        }
    }

    lateinit var transport: PcmReadAloudBridge
        private set
    private lateinit var session: MediaSession
    private lateinit var notificationManager: NotificationManager
    private lateinit var audioManager: AudioManager
    private var focusRequest: AudioFocusRequest? = null
    private var resumeAfterFocus = false
    private var foregroundReady = false
    private val mainHandler = Handler(Looper.getMainLooper())
    private val updatePlayback = object : Runnable {
        override fun run() {
            if (!foregroundReady) return
            updateMediaState()
            // Stop a finished, fully drained session rather than leaving an
            // invisible foreground service and media-focus session forever.
            val status = transport.status()
            val complete = status["complete"] == true
            val buffered = (status["bufferedMs"] as? Long) ?: 0L
            val position = (status["positionMs"] as? Long) ?: 0L
            if (complete && buffered > 0L && position >= buffered) {
                finishPlayback()
            } else {
                mainHandler.postDelayed(this, 1000L)
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        transport = PcmReadAloudBridge(applicationContext)
        current = this
        notificationManager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        notificationManager.createNotificationChannel(
            NotificationChannel(
                CHANNEL,
                "Lettura vocale AIVEXUS",
                NotificationManager.IMPORTANCE_LOW,
            )
        )
        session = MediaSession(this, "AIVEXUS read aloud")
        session.setCallback(object : MediaSession.Callback() {
            override fun onPlay() = play()
            override fun onPause() = pause()
            override fun onStop() = finishPlayback()
            override fun onSeekTo(pos: Long) {
                transport.seek(pos, relative = false)
                updateMediaState()
            }
            override fun onRewind() = jump(-10000L)
            override fun onFastForward() = jump(10000L)
        })
        session.setFlags(
            MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or
                MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS
        )
        session.setMetadata(
            MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, "Lettura AIVEXUS")
                .putString(MediaMetadata.METADATA_KEY_ARTIST, "Offline")
                .build()
        )
        session.isActive = true
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()
        focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(attributes)
            .setOnAudioFocusChangeListener { change ->
                when (change) {
                    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
                    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                        resumeAfterFocus = transport.status()["playing"] == true
                        transport.pause()
                        updateMediaState()
                    }
                    AudioManager.AUDIOFOCUS_LOSS -> {
                        resumeAfterFocus = false
                        transport.pause()
                        updateMediaState()
                    }
                    AudioManager.AUDIOFOCUS_GAIN -> {
                        if (resumeAfterFocus) {
                            resumeAfterFocus = false
                            transport.resume()
                            updateMediaState()
                        }
                    }
                }
            }.build()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                if (!foregroundReady) {
                    try {
                        startForeground(NOTIFICATION_ID, makeNotification())
                        foregroundReady = true
                        requestFocus()
                        mainHandler.post(updatePlayback)
                        completeStartup(this, null)
                    } catch (error: Exception) {
                        completeStartup(null, error.message ?: "Foreground media startup failed")
                        stopSelf()
                    }
                }
            }
            ACTION_PAUSE -> pause()
            ACTION_PLAY -> play()
            ACTION_REWIND -> jump(-10000L)
            ACTION_FORWARD -> jump(10000L)
            ACTION_STOP -> finishPlayback()
            else -> {
                // START_NOT_STICKY: never silently resurrect a previous TTS
                // session after process death or a system restart.
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    private fun requestFocus(): Boolean {
        val request = focusRequest ?: return false
        return audioManager.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun play() {
        if (!requestFocus()) {
            transport.pause()
            updateMediaState()
            return
        }
        transport.resume()
        updateMediaState()
    }

    private fun pause() {
        resumeAfterFocus = false
        transport.pause()
        updateMediaState()
    }

    private fun jump(offsetMs: Long) {
        transport.seek(offsetMs, relative = true)
        updateMediaState()
    }

    fun updateMediaState() {
        if (!foregroundReady) return
        val status = transport.status()
        val paused = status["paused"] == true
        val playing = status["playing"] == true
        val pos = (status["positionMs"] as? Long) ?: 0L
        val buffered = (status["bufferedMs"] as? Long) ?: 0L
        val state = when {
            playing -> PlaybackState.STATE_PLAYING
            paused -> PlaybackState.STATE_PAUSED
            else -> PlaybackState.STATE_BUFFERING
        }
        session.setPlaybackState(
            PlaybackState.Builder()
                .setActions(
                    PlaybackState.ACTION_PLAY or
                    PlaybackState.ACTION_PAUSE or
                    PlaybackState.ACTION_STOP or
                    PlaybackState.ACTION_SEEK_TO or
                    PlaybackState.ACTION_REWIND or
                    PlaybackState.ACTION_FAST_FORWARD
                )
                .setState(state, pos, if (playing) 1f else 0f)
                .setBufferedPosition(buffered)
                .build()
        )
        notificationManager.notify(NOTIFICATION_ID, makeNotification())
    }

    private fun pendingAction(action: String, requestCode: Int): PendingIntent {
        val intent = Intent(this, PcmReadAloudMediaService::class.java)
            .setAction(action)
        return PendingIntent.getService(
            this,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun makeNotification(): Notification {
        val paused = if (::transport.isInitialized) transport.status()["paused"] == true else false
        val pauseOrPlay = if (paused) ACTION_PLAY else ACTION_PAUSE
        val playIcon = if (paused) android.R.drawable.ic_media_play
            else android.R.drawable.ic_media_pause
        val contentIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("AIVEXUS · Lettura vocale")
            .setContentText(if (paused) "In pausa · tocca Riprendi" else "Audio offline")
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .addAction(
                Notification.Action.Builder(
                    android.R.drawable.ic_media_rew,
                    "Indietro 10 s",
                    pendingAction(ACTION_REWIND, 1)
                ).build()
            )
            .addAction(
                Notification.Action.Builder(
                    playIcon,
                    if (paused) "Riprendi" else "Pausa",
                    pendingAction(pauseOrPlay, 2)
                ).build()
            )
            .addAction(
                Notification.Action.Builder(
                    android.R.drawable.ic_media_ff,
                    "Avanti 10 s",
                    pendingAction(ACTION_FORWARD, 3)
                ).build()
            )
            .addAction(
                Notification.Action.Builder(
                    android.R.drawable.ic_menu_close_clear_cancel,
                    "Chiudi",
                    pendingAction(ACTION_STOP, 4)
                ).build()
            )
            .setStyle(
                Notification.MediaStyle()
                    .setMediaSession(session.sessionToken)
                    .setShowActionsInCompactView(0, 1, 2)
            )
            .build()
    }

    fun finishPlayback() {
        if (!foregroundReady) return
        transport.releaseLocked()
        resumeAfterFocus = false
        focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
        foregroundReady = false
        mainHandler.removeCallbacks(updatePlayback)
        session.setPlaybackState(
            PlaybackState.Builder()
                .setState(PlaybackState.STATE_STOPPED, 0L, 0f)
                .build()
        )
        if (Build.VERSION.SDK_INT >= 24) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    override fun onDestroy() {
        foregroundReady = false
        mainHandler.removeCallbacks(updatePlayback)
        focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
        transport.close()
        session.isActive = false
        session.release()
        if (current === this) current = null
        completeStartup(null, "Playback service was stopped")
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}

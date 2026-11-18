package dev.aivexus.adskill;

import android.content.Context;
import android.content.SharedPreferences;
import android.media.AudioManager;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

/**
 * Experimental, GLOBAL media-stream volume control for an allowed ad window.
 * It cannot isolate one application's audio. Values are restored only if the
 * current media volume is still zero, to avoid overriding user adjustments.
 * A crash-safe preference allows a later service startup to restore volume.
 */
final class SessionAudio {
    private static final String PREFS = "ads_kill";
    private static final String SAVED = "audio_restore_pending";
    private static final String ORIGINAL = "audio_original_volume";

    private final Context context;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final AudioManager audio;
    private final SharedPreferences prefs;

    private long untilEpoch = 0L;
    private final Runnable expiry = new Runnable() {
        @Override public void run() {
            long remaining = untilEpoch - System.currentTimeMillis();
            if (remaining > 0L) main.postDelayed(this, Math.min(remaining, 1000L));
            else restore();
        }
    };

    SessionAudio(Context context) {
        this.context = context;
        this.audio = context.getSystemService(AudioManager.class);
        this.prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    /**
     * Opt-in preference defaults to on as requested, but is explicitly
     * disclosed in settings. Any other playing media may also be muted.
     */
    void begin(long until) {
        untilEpoch = until;
        main.removeCallbacks(expiry);
        if (!prefs.getBoolean("planned_mute", true)) {
            restore();
            return;
        }
        if (audio == null) return;
        try {
            if (!prefs.getBoolean(SAVED, false)) {
                int original = audio.getStreamVolume(AudioManager.STREAM_MUSIC);
                // The durable value is committed BEFORE adjusting global volume.
                prefs.edit().putInt(ORIGINAL, original)
                    .putBoolean(SAVED, original > 0).commit();
                if (original > 0) {
                    audio.setStreamVolume(AudioManager.STREAM_MUSIC, 0, 0);
                }
            }
        } catch (SecurityException | IllegalArgumentException e) {
            Log.w("AdsKill", "Cannot mute system media volume", e);
            prefs.edit().putBoolean(SAVED, false).apply();
        }
        main.postDelayed(expiry, Math.max(1000L, until - System.currentTimeMillis()));
    }

    void recoverStale() {
        if (prefs.getBoolean(SAVED, false)) restore();
    }

    void restore() {
        main.removeCallbacks(expiry);
        untilEpoch = 0L;
        boolean pending = prefs.getBoolean(SAVED, false);
        int volume = prefs.getInt(ORIGINAL, 0);
        if (!pending) return;
        try {
            if (audio != null && volume > 0
                    && audio.getStreamVolume(AudioManager.STREAM_MUSIC) == 0) {
                audio.setStreamVolume(AudioManager.STREAM_MUSIC, volume, 0);
            }
        } catch (SecurityException | IllegalArgumentException e) {
            Log.w("AdsKill", "Cannot restore media volume automatically", e);
        } finally {
            prefs.edit().remove(SAVED).remove(ORIGINAL).apply();
        }
    }
}

import 'dart:async';
import 'dart:typed_data';

import 'package:mp_audio_stream/mp_audio_stream.dart';

import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';

/// Low-latency PCM audio output powered by [mp_audio_stream].
///
/// Serialises concurrent [push] calls into a sequential playback queue so
/// that sentence chunks received from the TTS engine play one after another
/// without overlap.  Barge-in is handled by [stop], which cancels any
/// in-progress chunk and clears the queue.
///
/// Usage
/// ──────
/// ```dart
/// final player = AudioStreamPlayer();
/// player.push(samples, sampleRate);  // fire-and-forget
/// // …
/// player.stop();   // barge-in / session end
/// player.dispose(); // widget / engine dispose
/// ```
class AudioStreamPlayer with RuntimeEventEmitter {
  static const String _tag = 'AUDIO_PLAYER';

  // Native hardware state.
  bool _initialized = false;
  int _initSampleRate = 0;

  // Stop flag checked by the active play loop on every 50 ms tick.
  bool _stopRequested = false;

  // Counts chunks that are in-flight (playing or queued) so that [isPlaying]
  // reflects actual queue depth instead of a simple bool toggle.
  int _queueDepth = 0;

  // Serial playback queue implemented as a Future chain.  Each [push] call
  // appends a new link so that chunks execute one after the other.
  Future<void> _tail = Future<void>.value();

  /// `true` while audio is actively playing or queued to play.
  bool get isPlaying => _queueDepth > 0;

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Enqueues [samples] (mono Float32 at [sampleRate] Hz) for serial playback.
  ///
  /// The call returns immediately; actual playback begins once all previously
  /// enqueued chunks have finished.  If [stop] was called since the last [push]
  /// the samples are silently discarded.
  void push(Float32List samples, int sampleRate) {
    // Reset the stop flag so a new TTS session can begin after a barge-in.
    _stopRequested = false;
    _queueDepth++;

    final prev = _tail;
    _tail = Future<void>(() async {
      await prev;
      try {
        if (!_stopRequested) {
          await _doPlay(samples, sampleRate);
        }
      } finally {
        if (_queueDepth > 0) _queueDepth--;
      }
    });
  }

  /// Stops playback immediately, clears the queue, and releases the hardware
  /// audio buffer so that no residual audio remains in the speaker pipeline.
  ///
  /// Call this on barge-in or when ending a voice session.
  void stop() {
    logEvent(_tag, '[STOP_REQUESTED] queueDepth=$_queueDepth');
    _stopRequested = true;
    _queueDepth = 0;
    // Reset the serial tail so future pushes start fresh.
    _tail = Future<void>.value();
    // Tear down the hardware buffer to flush any queued audio instantly.
    _tearDownNative();
  }

  /// Releases all native resources.  Must be called once from the owning
  /// engine's [dispose] method.
  void dispose() {
    logEvent(_tag, '[DISPOSE_BEGIN]');
    _stopRequested = true;
    _queueDepth = 0;
    _tail = Future<void>.value();
    _tearDownNative();
    logEvent(_tag, '[DISPOSE_DONE]');
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  Future<void> _doPlay(Float32List samples, int sampleRate) async {
    try {
      await _ensureInit(sampleRate);
    } catch (e) {
      logEvent(_tag, '[PLAY_INIT_FAIL] $e');
      return;
    }

    if (_stopRequested) return;

    final durationMs = (samples.length / sampleRate * 1000).round();

    logEvent(
      _tag,
      '[PLAY_BEGIN] samples=${samples.length} sampleRate=$sampleRate '
      'durationMs=${durationMs}ms',
    );

    // Push samples to the hardware ring-buffer.
    getAudioStream().push(samples);

    // Wait for the approximate playback duration, waking every 50 ms so that
    // a [stop] call is honoured within one polling tick (~50 ms latency).
    var waited = 0;
    while (waited < durationMs && !_stopRequested) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      waited += 50;
    }

    logEvent(_tag, '[PLAY_DONE] stopped=$_stopRequested waited=${waited}ms');
  }

  Future<void> _ensureInit(int sampleRate) async {
    if (_initialized && _initSampleRate == sampleRate) return;

    _tearDownNative();

    // 1 000 ms ring-buffer: enough for a sentence chunk while still providing
    // a sub-second response to barge-in after [stop] + [_tearDownNative].
    getAudioStream().init(
      sampleRate: sampleRate,
      channels: 1,
      bufferMilliSec: 1000,
    );

    _initialized = true;
    _initSampleRate = sampleRate;
    logEvent(_tag, '[INIT_OK] sampleRate=$sampleRate bufferMilliSec=1000');
  }

  void _tearDownNative() {
    if (_initialized) {
      try {
        getAudioStream().uninit();
        logEvent(_tag, '[UNINIT_OK]');
      } catch (e) {
        logEvent(_tag, '[UNINIT_FAIL] $e');
      }
      _initialized = false;
    }
  }
}

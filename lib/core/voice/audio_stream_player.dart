import 'dart:async';
import 'dart:math' as math;
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
/// This class also exposes detailed runtime diagnostics for the audio path:
///
///   TTS
///    ↓
///   PCM Float32
///    ↓
///   AudioStreamPlayer
///    ↓
///   mp_audio_stream
///    ↓
///   Android audio output
///
/// The diagnostics deliberately distinguish:
///
///   - no samples;
///   - silent PCM;
///   - invalid PCM;
///   - valid PCM successfully submitted to the native stream.
///
/// This allows the audio problem to be diagnosed before changing volume,
/// speaker controls, UI controls, or the voice-session architecture.
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

  // Serial playback queue implemented as a Future chain. Each [push] call
  // appends a new link so that chunks execute one after the other.
  Future<void> _tail = Future<void>.value();

  // Monotonic counter used only for diagnostics.
  int _chunkSequence = 0;

  /// `true` while audio is actively playing or queued to play.
  bool get isPlaying => _queueDepth > 0;

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Enqueues [samples] (mono Float32 at [sampleRate] Hz) for serial playback.
  ///
  /// The call returns immediately; actual playback begins once all previously
  /// enqueued chunks have finished. If [stop] was called since the last [push]
  /// the samples are silently discarded.
  void push(Float32List samples, int sampleRate) {
    _stopRequested = false;

    final chunkId = ++_chunkSequence;

    logEvent(
      _tag,
      '[PUSH_RECEIVED] '
      'chunk=$chunkId '
      'samples=${samples.length} '
      'sampleRate=$sampleRate '
      'queueDepthBefore=$_queueDepth',
    );

    _logPcmDiagnostics(
      chunkId: chunkId,
      samples: samples,
      sampleRate: sampleRate,
    );

    if (samples.isEmpty) {
      logEvent(
        _tag,
        '[PUSH_REJECTED] chunk=$chunkId reason=empty_pcm',
      );
      return;
    }

    if (sampleRate <= 0) {
      logEvent(
        _tag,
        '[PUSH_REJECTED] '
        'chunk=$chunkId '
        'reason=invalid_sample_rate '
        'sampleRate=$sampleRate',
      );
      return;
    }

    _queueDepth++;

    final prev = _tail;

    _tail = Future<void>(() async {
      await prev;

      try {
        if (_stopRequested) {
          logEvent(
            _tag,
            '[PLAY_SKIPPED] '
            'chunk=$chunkId '
            'reason=stop_requested',
          );
          return;
        }

        await _doPlay(
          samples,
          sampleRate,
          chunkId: chunkId,
        );
      } finally {
        if (_queueDepth > 0) {
          _queueDepth--;
        }

        logEvent(
          _tag,
          '[QUEUE_CHUNK_FINISHED] '
          'chunk=$chunkId '
          'queueDepth=$_queueDepth',
        );
      }
    });
  }

  /// Stops playback immediately, clears the queue, and releases the hardware
  /// audio buffer so that no residual audio remains in the speaker pipeline.
  ///
  /// Call this on barge-in or when ending a voice session.
  void stop() {
    logEvent(
      _tag,
      '[STOP_REQUESTED] queueDepth=$_queueDepth',
    );

    _stopRequested = true;
    _queueDepth = 0;

    // Reset the serial tail so future pushes start fresh.
    _tail = Future<void>.value();

    // Tear down the hardware buffer to flush any queued audio instantly.
    _tearDownNative();
  }

  /// Releases all native resources. Must be called once from the owning
  /// engine's [dispose] method.
  void dispose() {
    logEvent(
      _tag,
      '[DISPOSE_BEGIN]',
    );

    _stopRequested = true;
    _queueDepth = 0;
    _tail = Future<void>.value();

    _tearDownNative();

    logEvent(
      _tag,
      '[DISPOSE_DONE]',
    );
  }

  // ── Playback ───────────────────────────────────────────────────────────────

  Future<void> _doPlay(
    Float32List samples,
    int sampleRate, {
    required int chunkId,
  }) async {
    try {
      await _ensureInit(sampleRate);
    } catch (e) {
      logEvent(
        _tag,
        '[PLAY_INIT_FAIL] '
        'chunk=$chunkId '
        'error=$e',
      );
      return;
    }

    if (_stopRequested) {
      logEvent(
        _tag,
        '[PLAY_ABORTED_BEFORE_PUSH] '
        'chunk=$chunkId '
        'reason=stop_requested',
      );
      return;
    }

    final durationMs =
        (samples.length / sampleRate * 1000).round();

    logEvent(
      _tag,
      '[PLAY_BEGIN] '
      'chunk=$chunkId '
      'samples=${samples.length} '
      'sampleRate=$sampleRate '
      'durationMs=${durationMs}ms '
      'queueDepth=$_queueDepth',
    );

    try {
      // Push samples to the hardware ring-buffer.
      getAudioStream().push(samples);

      logEvent(
        _tag,
        '[NATIVE_PUSH_OK] '
        'chunk=$chunkId '
        'samples=${samples.length} '
        'sampleRate=$sampleRate',
      );
    } catch (e) {
      logEvent(
        _tag,
        '[NATIVE_PUSH_FAIL] '
        'chunk=$chunkId '
        'error=$e',
      );
      return;
    }

    // Wait for the approximate playback duration, waking every 50 ms so that
    // a [stop] call is honoured within one polling tick (~50 ms latency).
    var waited = 0;

    while (waited < durationMs && !_stopRequested) {
      await Future<void>.delayed(
        const Duration(milliseconds: 50),
      );
      waited += 50;
    }

    logEvent(
      _tag,
      '[PLAY_DONE] '
      'chunk=$chunkId '
      'stopped=$_stopRequested '
      'waited=${waited}ms '
      'expected=${durationMs}ms',
    );
  }

  // ── Native lifecycle ──────────────────────────────────────────────────────

  Future<void> _ensureInit(int sampleRate) async {
    if (_initialized && _initSampleRate == sampleRate) {
      logEvent(
        _tag,
        '[INIT_REUSE] '
        'sampleRate=$sampleRate',
      );
      return;
    }

    if (_initialized &&
        _initSampleRate != sampleRate) {
      logEvent(
        _tag,
        '[INIT_SAMPLE_RATE_CHANGE] '
        'oldSampleRate=$_initSampleRate '
        'newSampleRate=$sampleRate',
      );
    }

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

    logEvent(
      _tag,
      '[INIT_OK] '
      'sampleRate=$sampleRate '
      'channels=1 '
      'bufferMilliSec=1000',
    );
  }

  void _tearDownNative() {
    if (!_initialized) {
      logEvent(
        _tag,
        '[UNINIT_SKIP] reason=not_initialized',
      );
      return;
    }

    try {
      getAudioStream().uninit();

      logEvent(
        _tag,
        '[UNINIT_OK] '
        'sampleRate=$_initSampleRate',
      );
    } catch (e) {
      logEvent(
        _tag,
        '[UNINIT_FAIL] '
        'error=$e',
      );
    }

    _initialized = false;
    _initSampleRate = 0;
  }

  // ── PCM diagnostics ───────────────────────────────────────────────────────

  /// Analyses the PCM before it reaches the native audio layer.
  ///
  /// This is intentionally diagnostic-only. It does not modify the samples.
  ///
  /// The most important values are:
  ///
  ///   peak
  ///       Maximum absolute PCM amplitude.
  ///
  ///   rms
  ///       Overall signal energy.
  ///
  ///   zeroPercent
  ///       Percentage of exact-zero samples.
  ///
  ///   nonFinite
  ///       NaN / Infinity samples.
  ///
  /// Interpretation:
  ///
  ///   peak == 0
  ///       Definite digital silence.
  ///
  ///   very small peak / RMS
  ///       Possible near-silence or extremely low TTS gain.
  ///
  ///   healthy non-zero PCM
  ///       The problem is downstream of PCM generation and should not
  ///       initially be treated as a simple TTS-volume problem.
  void _logPcmDiagnostics({
    required int chunkId,
    required Float32List samples,
    required int sampleRate,
  }) {
    if (samples.isEmpty) {
      return;
    }

    var min = double.infinity;
    var max = double.negativeInfinity;
    var peak = 0.0;
    var sumSquares = 0.0;
    var zeroSamples = 0;
    var nonFiniteSamples = 0;

    for (final sample in samples) {
      final value = sample.toDouble();

      if (!value.isFinite) {
        nonFiniteSamples++;
        continue;
      }

      if (value < min) {
        min = value;
      }

      if (value > max) {
        max = value;
      }

      final absolute = value.abs();

      if (absolute > peak) {
        peak = absolute;
      }

      if (absolute == 0.0) {
        zeroSamples++;
      }

      sumSquares += value * value;
    }

    final finiteSamples =
        samples.length - nonFiniteSamples;

    final rms = finiteSamples == 0
        ? 0.0
        : math.sqrt(
            sumSquares / finiteSamples,
          );

    final zeroPercent =
        (zeroSamples / samples.length) * 100.0;

    final durationMs =
        (samples.length / sampleRate * 1000).round();

    final classification =
        _classifyPcm(
      peak: peak,
      rms: rms,
      nonFiniteSamples: nonFiniteSamples,
    );

    logEvent(
      _tag,
      '[PCM_DIAGNOSTICS] '
      'chunk=$chunkId '
      'samples=${samples.length} '
      'sampleRate=$sampleRate '
      'durationMs=$durationMs '
      'min=${_formatAudioValue(min)} '
      'max=${_formatAudioValue(max)} '
      'peak=${_formatAudioValue(peak)} '
      'rms=${_formatAudioValue(rms)} '
      'zeroSamples=$zeroSamples '
      'zeroPercent=${zeroPercent.toStringAsFixed(2)} '
      'nonFinite=$nonFiniteSamples '
      'classification=$classification',
    );
  }

  String _classifyPcm({
    required double peak,
    required double rms,
    required int nonFiniteSamples,
  }) {
    if (nonFiniteSamples > 0) {
      return 'INVALID_PCM';
    }

    if (peak == 0.0) {
      return 'PCM_SILENCE';
    }

    // Float PCM normally occupies approximately [-1, 1].
    // This threshold is diagnostic only and deliberately conservative.
    if (peak < 0.001 && rms < 0.0003) {
      return 'PCM_NEAR_SILENCE';
    }

    return 'PCM_SIGNAL_PRESENT';
  }

  String _formatAudioValue(double value) {
    if (!value.isFinite) {
      return value.toString();
    }

    return value.toStringAsFixed(6);
  }
}

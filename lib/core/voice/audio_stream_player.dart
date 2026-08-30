import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:mp_audio_stream/mp_audio_stream.dart';

import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';

/// Low-latency PCM audio output powered by [mp_audio_stream].
///
/// Serialises concurrent [push] calls into a sequential playback queue so
/// that sentence chunks received from the TTS engine play one after another
/// without overlap. Barge-in is handled by [stop], which invalidates any
/// in-progress or queued chunk and clears the queue.
///
/// IMPORTANT:
/// [getAudioStream()] creates a new [AudioStream] instance on every call.
/// The native FFI callbacks (_pushFfi, _uninitFfi, statistics callbacks) are
/// initialized on the instance by [AudioStream.init].
///
/// Therefore this class owns exactly one AudioStream instance and uses that
/// same instance for init(), push(), uninit(), resume(), and statistics.
///
/// The native mp_audio_stream implementation returns -1 from push() when
/// its native playback buffer is full. TTS sentences can be several seconds
/// long, while the native buffer is intentionally much smaller. Therefore
/// this class performs bounded PCM streaming with back-pressure instead of
/// attempting to submit an entire TTS sentence in one native call.
///
/// Audio path:
///
///   TTS
///    ↓
///   PCM Float32
///    ↓
///   AudioStreamPlayer
///    ↓
///   bounded PCM slices
///    ↓
///   mp_audio_stream
///    ↓
///   Android audio output
///
/// Usage
/// ──────
/// ```dart
/// final player = AudioStreamPlayer();
/// player.push(samples, sampleRate);
/// player.stop();
/// player.dispose();
/// ```
class AudioStreamPlayer with RuntimeEventEmitter {
  static const String _tag = 'AUDIO_PLAYER';

  /// The same AudioStream instance must be used for init(), push(), and
  /// uninit(). Creating a second instance would leave its late FFI fields
  /// uninitialized and reproduce the original LateInitializationError.
  final AudioStream _audioStream = getAudioStream();

  // Native hardware state.
  bool _initialized = false;
  int _initSampleRate = 0;

  // Stop flag checked by the active streaming loop.
  bool _stopRequested = false;

  // Monotonic lifecycle generation.
  int _lifecycleGeneration = 0;

  // Number of complete TTS chunks queued/in-flight.
  int _queueDepth = 0;

  // Serial playback queue.
  Future<void> _tail = Future<void>.value();

  // Diagnostic chunk counter.
  int _chunkSequence = 0;

  // Permanently disposed state.
  bool _disposed = false;

  /// Native ring buffer duration.
  ///
  /// Keep this deliberately bounded. The player streams large TTS sentences
  /// into this buffer progressively instead of allocating one giant native
  /// submission.
  static const int _bufferMilliSec = 1000;

  /// Native waiting buffer.
  static const int _waitingBufferMilliSec = 100;

  /// Size of every PCM slice submitted to native.
  ///
  /// 200 ms at 22050 Hz = 4410 float samples.
  ///
  /// This is small enough to provide responsive barge-in while large enough
  /// to avoid excessive FFI calls.
  static const int _pushSliceMilliSec = 200;

  /// Delay before retrying a native push after the native buffer reports full.
  static const Duration _nativeRetryDelay =
      Duration(milliseconds: 25);

  /// Maximum number of consecutive retries for one slice before reporting
  /// an actual native streaming failure.
  ///
  /// At 25 ms this gives approximately 2.5 seconds of tolerance.
  static const int _maxPushRetries = 100;

  /// `true` while audio is actively playing or queued to play.
  bool get isPlaying => _queueDepth > 0;

  // ── Public API ────────────────────────────────────────────────────────────

  /// Enqueues [samples] (mono Float32 at [sampleRate] Hz) for serial playback.
  ///
  /// The method returns immediately. Actual native submission happens through
  /// the serial Future queue.
  ///
  /// Large TTS buffers are split into small PCM slices because
  /// mp_audio_stream.push() returns -1 when its native buffer is full.
  void push(Float32List samples, int sampleRate) {
    final chunkId = ++_chunkSequence;
    final generation = _lifecycleGeneration;

    if (_disposed) {
      logEvent(
        _tag,
        '[PUSH_REJECTED] '
        'chunk=$chunkId '
        'reason=disposed',
      );
      return;
    }

    _stopRequested = false;

    logEvent(
      _tag,
      '[PUSH_RECEIVED] '
      'chunk=$chunkId '
      'samples=${samples.length} '
      'sampleRate=$sampleRate '
      'queueDepthBefore=$_queueDepth '
      'generation=$generation',
    );

    _logPcmDiagnostics(
      chunkId: chunkId,
      samples: samples,
      sampleRate: sampleRate,
    );

    if (samples.isEmpty) {
      logEvent(
        _tag,
        '[PUSH_REJECTED] '
        'chunk=$chunkId '
        'reason=empty_pcm',
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

    final previous = _tail;

    _tail = Future<void>(() async {
      await previous;

      try {
        if (_disposed ||
            generation != _lifecycleGeneration ||
            _stopRequested) {
          logEvent(
            _tag,
            '[PLAY_SKIPPED] '
            'chunk=$chunkId '
            'reason=lifecycle_invalidated '
            'generation=$generation '
            'currentGeneration=$_lifecycleGeneration '
            'disposed=$_disposed '
            'stopRequested=$_stopRequested',
          );
          return;
        }

        await _doPlay(
          samples,
          sampleRate,
          chunkId: chunkId,
          generation: generation,
        );
      } finally {
        if (generation == _lifecycleGeneration) {
          if (_queueDepth > 0) {
            _queueDepth--;
          }

          logEvent(
            _tag,
            '[QUEUE_CHUNK_FINISHED] '
            'chunk=$chunkId '
            'queueDepth=$_queueDepth '
            'generation=$generation',
          );
        } else {
          logEvent(
            _tag,
            '[QUEUE_CHUNK_INVALIDATED] '
            'chunk=$chunkId '
            'generation=$generation '
            'currentGeneration=$_lifecycleGeneration '
            'queueDepth=$_queueDepth',
          );
        }
      }
    });
  }

  /// Stops playback immediately and invalidates the current generation.
  void stop() {
    if (_disposed) {
      logEvent(
        _tag,
        '[STOP_IGNORED] reason=disposed',
      );
      return;
    }

    logEvent(
      _tag,
      '[STOP_REQUESTED] '
      'queueDepth=$_queueDepth '
      'generation=$_lifecycleGeneration',
    );

    _lifecycleGeneration++;

    _stopRequested = true;
    _queueDepth = 0;

    _tail = Future<void>.value();

    _tearDownNative();

    logEvent(
      _tag,
      '[STOP_COMPLETE] '
      'generation=$_lifecycleGeneration',
    );
  }

  /// Releases all native resources.
  void dispose() {
    if (_disposed) {
      logEvent(
        _tag,
        '[DISPOSE_IGNORED] reason=already_disposed',
      );
      return;
    }

    logEvent(
      _tag,
      '[DISPOSE_BEGIN]',
    );

    _lifecycleGeneration++;

    _disposed = true;
    _stopRequested = true;
    _queueDepth = 0;
    _tail = Future<void>.value();

    _tearDownNative();

    logEvent(
      _tag,
      '[DISPOSE_DONE] '
      'generation=$_lifecycleGeneration',
    );
  }

  // ── Playback ──────────────────────────────────────────────────────────────

  Future<void> _doPlay(
    Float32List samples,
    int sampleRate, {
    required int chunkId,
    required int generation,
  }) async {
    if (_disposed ||
        generation != _lifecycleGeneration ||
        _stopRequested) {
      logEvent(
        _tag,
        '[PLAY_REJECTED_BEFORE_INIT] '
        'chunk=$chunkId '
        'reason=lifecycle_invalidated '
        'generation=$generation '
        'currentGeneration=$_lifecycleGeneration',
      );
      return;
    }

    try {
      await _ensureInit(
        sampleRate,
        chunkId: chunkId,
        generation: generation,
      );
    } catch (e) {
      logEvent(
        _tag,
        '[PLAY_INIT_FAIL] '
        'chunk=$chunkId '
        'error=$e',
      );
      return;
    }

    if (_disposed ||
        generation != _lifecycleGeneration ||
        _stopRequested) {
      logEvent(
        _tag,
        '[PLAY_ABORTED_BEFORE_PUSH] '
        'chunk=$chunkId '
        'reason=lifecycle_invalidated '
        'generation=$generation '
        'currentGeneration=$_lifecycleGeneration '
        'stopRequested=$_stopRequested',
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
      'queueDepth=$_queueDepth '
      'generation=$generation',
    );

    await _streamPcm(
      samples,
      sampleRate,
      chunkId: chunkId,
      generation: generation,
    );

    if (_disposed ||
        generation != _lifecycleGeneration ||
        _stopRequested) {
      logEvent(
        _tag,
        '[PLAY_DONE] '
        'chunk=$chunkId '
        'stopped=$_stopRequested '
        'disposed=$_disposed '
        'generation=$generation '
        'currentGeneration=$_lifecycleGeneration '
        'reason=lifecycle_invalidated',
      );
      return;
    }

    logEvent(
      _tag,
      '[PLAY_DONE] '
      'chunk=$chunkId '
      'stopped=$_stopRequested '
      'disposed=$_disposed '
      'generation=$generation '
      'currentGeneration=$_lifecycleGeneration '
      'streamed=${durationMs}ms '
      'expected=${durationMs}ms',
    );
  }

  /// Streams one complete TTS PCM chunk through the native ring buffer.
  ///
  /// The critical difference from the previous implementation is that this
  /// method NEVER submits the complete 5–12 second TTS buffer in one call.
  ///
  /// Instead:
  ///
  ///   Float32List sentence
  ///          ↓
  ///   200 ms slice
  ///          ↓
  ///   native push()
  ///          ↓
  ///   result == 0 → continue
  ///   result == -1 → wait and retry
  ///
  /// This matches mp_audio_stream's documented back-pressure behaviour.
  Future<void> _streamPcm(
    Float32List samples,
    int sampleRate, {
    required int chunkId,
    required int generation,
  }) async {
    final sliceSamples = math.max(
      1,
      (sampleRate * _pushSliceMilliSec / 1000).round(),
    );

    var offset = 0;
    var sliceId = 0;

    while (offset < samples.length) {
      if (_disposed ||
          generation != _lifecycleGeneration ||
          _stopRequested) {
        logEvent(
          _tag,
          '[STREAM_ABORTED] '
          'chunk=$chunkId '
          'offset=$offset '
          'totalSamples=${samples.length} '
          'generation=$generation '
          'currentGeneration=$_lifecycleGeneration',
        );
        return;
      }

      final end = math.min(
        offset + sliceSamples,
        samples.length,
      );

      final slice = Float32List.sublistView(
        samples,
        offset,
        end,
      );

      sliceId++;

      final result = await _pushSliceWithBackpressure(
        slice,
        chunkId: chunkId,
        sliceId: sliceId,
        sampleRate: sampleRate,
        generation: generation,
      );

      if (!result) {
        logEvent(
          _tag,
          '[STREAM_ABORTED] '
          'chunk=$chunkId '
          'slice=$sliceId '
          'offset=$offset '
          'totalSamples=${samples.length} '
          'generation=$generation',
        );
        return;
      }

      offset = end;
    }

    logEvent(
      _tag,
      '[STREAM_COMPLETE] '
      'chunk=$chunkId '
      'slices=$sliceId '
      'samples=${samples.length} '
      'sampleRate=$sampleRate',
    );
  }

  /// Pushes one bounded PCM slice and applies back-pressure when native
  /// reports that its ring buffer is full.
  Future<bool> _pushSliceWithBackpressure(
    Float32List slice, {
    required int chunkId,
    required int sliceId,
    required int sampleRate,
    required int generation,
  }) async {
    var retries = 0;

    while (true) {
      if (_disposed ||
          generation != _lifecycleGeneration ||
          _stopRequested) {
        return false;
      }

      int result;

      try {
        // IMPORTANT:
        // This is the SAME AudioStream instance that was initialized by
        // _ensureInit(). This prevents the original _pushFfi
        // LateInitializationError.
        result = _audioStream.push(slice);
      } catch (e) {
        logEvent(
          _tag,
          '[NATIVE_PUSH_EXCEPTION] '
          'chunk=$chunkId '
          'slice=$sliceId '
          'attempt=${retries + 1} '
          'samples=${slice.length} '
          'sampleRate=$sampleRate '
          'error=$e',
        );
        return false;
      }

      logEvent(
        _tag,
        '[NATIVE_PUSH_RESULT] '
        'chunk=$chunkId '
        'slice=$sliceId '
        'attempt=${retries + 1} '
        'result=$result '
        'samples=${slice.length} '
        'sampleRate=$sampleRate',
      );

      if (result == 0) {
        logEvent(
          _tag,
          '[NATIVE_PUSH_OK] '
          'chunk=$chunkId '
          'slice=$sliceId '
          'samples=${slice.length} '
          'sampleRate=$sampleRate',
        );
        return true;
      }

      // mp_audio_stream returns -1 when the native playback buffer is full.
      if (result == -1) {
        retries++;

        if (retries > _maxPushRetries) {
          AudioStreamStat? stat;

          try {
            stat = _audioStream.stat();
          } catch (_) {
            // Diagnostic only.
          }

          logEvent(
            _tag,
            '[NATIVE_PUSH_FAIL] '
            'chunk=$chunkId '
            'slice=$sliceId '
            'result=$result '
            'reason=buffer_full_timeout '
            'retries=$retries '
            'statFull=${stat?.full} '
            'statExhaust=${stat?.exhaust}',
          );

          return false;
        }

        if (retries == 1 || retries % 10 == 0) {
          AudioStreamStat? stat;

          try {
            stat = _audioStream.stat();
          } catch (_) {
            // Diagnostic only.
          }

          logEvent(
            _tag,
            '[NATIVE_PUSH_BACKPRESSURE] '
            'chunk=$chunkId '
            'slice=$sliceId '
            'result=$result '
            'retry=$retries '
            'statFull=${stat?.full} '
            'statExhaust=${stat?.exhaust}',
          );
        }

        await Future<void>.delayed(
          _nativeRetryDelay,
        );

        continue;
      }

      logEvent(
        _tag,
        '[NATIVE_PUSH_FAIL] '
        'chunk=$chunkId '
        'slice=$sliceId '
        'result=$result '
        'reason=unexpected_native_result',
      );

      return false;
    }
  }

  // ── Native lifecycle ──────────────────────────────────────────────────────

  Future<void> _ensureInit(
    int sampleRate, {
    required int chunkId,
    required int generation,
  }) async {
    if (_disposed ||
        generation != _lifecycleGeneration ||
        _stopRequested) {
      throw StateError(
        'Audio player lifecycle invalidated before init.',
      );
    }

    if (_initialized && _initSampleRate == sampleRate) {
      logEvent(
        _tag,
        '[INIT_REUSE] '
        'sampleRate=$sampleRate '
        'generation=$generation',
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

    if (_disposed ||
        generation != _lifecycleGeneration ||
        _stopRequested) {
      throw StateError(
        'Audio player lifecycle invalidated during reinit.',
      );
    }

    final initResult = _audioStream.init(
      sampleRate: sampleRate,
      channels: 1,
      bufferMilliSec: _bufferMilliSec,
      waitingBufferMilliSec: _waitingBufferMilliSec,
    );

    logEvent(
      _tag,
      '[AUDIO_FFI_INIT_RESULT] '
      'result=$initResult '
      'sampleRate=$sampleRate '
      'channels=1 '
      'bufferMilliSec=$_bufferMilliSec '
      'waitingBufferMilliSec=$_waitingBufferMilliSec',
    );

    if (initResult != 0) {
      _initialized = false;
      _initSampleRate = 0;

      throw StateError(
        'mp_audio_stream.init failed with result=$initResult.',
      );
    }

    try {
      _audioStream.resetStat();
    } catch (e) {
      logEvent(
        _tag,
        '[AUDIO_STAT_RESET_WARN] '
        'error=$e',
      );
    }

    try {
      _audioStream.resume();

      logEvent(
        _tag,
        '[AUDIO_RESUME_OK] '
        'sampleRate=$sampleRate',
      );
    } catch (e) {
      logEvent(
        _tag,
        '[AUDIO_RESUME_WARN] '
        'error=$e',
      );
    }

    _initialized = true;
    _initSampleRate = sampleRate;

    logEvent(
      _tag,
      '[AUDIO_READY] '
      'sampleRate=$sampleRate '
      'channels=1 '
      'bufferMilliSec=$_bufferMilliSec '
      'waitingBufferMilliSec=$_waitingBufferMilliSec '
      'pushSliceMilliSec=$_pushSliceMilliSec '
      'generation=$generation',
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

    final sampleRate = _initSampleRate;

    _initialized = false;
    _initSampleRate = 0;

    try {
      // SAME AudioStream instance that performed init().
      _audioStream.uninit();

      logEvent(
        _tag,
        '[UNINIT_OK] '
        'sampleRate=$sampleRate',
      );
    } catch (e) {
      logEvent(
        _tag,
        '[UNINIT_FAIL] '
        'error=$e '
        'sampleRate=$sampleRate',
      );
    }
  }

  // ── PCM diagnostics ──────────────────────────────────────────────────────

  /// Analyses PCM before it reaches the native audio layer.
  ///
  /// Diagnostic only: samples are never modified.
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

    final classification = _classifyPcm(
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

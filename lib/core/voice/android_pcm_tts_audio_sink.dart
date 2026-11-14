import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'package:ai_orchestrator/core/voice/read_aloud_transport.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';

/// Android-only offline PCM output. The app-private native file keeps played
/// phrases available for real seek; no text is sent off-device.
class AndroidPcmTtsAudioSink implements TtsAudioSink, ReadAloudSink, ReadAloudResumeTarget {
  AndroidPcmTtsAudioSink({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('com.aiorchestrator/tts_pcm_transport');

  final MethodChannel _channel;
  Future<void> _queue = Future<void>.value();
  ReadAloudSnapshot _snapshot = const ReadAloudSnapshot(supported: true);
  bool _disposed = false;
  Object? _appendError;
  Duration _nextReadAloudPosition = Duration.zero;

  @override
  bool get isPlaying => !_disposed && _snapshot.playing;
  @override
  ReadAloudSnapshot get snapshot => _snapshot;

  Future<void> _send(String name, [Map<String, Object>? arguments]) {
    if (_disposed) return Future<void>.value();
    final next = _queue.then((_) async {
      await _channel.invokeMethod<void>(name, arguments);
    });
    // Always leave the queue usable after a native I/O failure. The error is
    // still propagated to callers of this specific operation.
    _queue = next.catchError((Object error) {
      _appendError = error;
    });
    return next;
  }

  @override
  void setNextReadAloudPosition(Duration position) {
    _nextReadAloudPosition = position > Duration.zero
        ? position : Duration.zero;
  }

  @override
  Future<void> beginReadAloud() async {
    _appendError = null;
    final bookmark = _nextReadAloudPosition;
    _nextReadAloudPosition = Duration.zero;
    await _send('prepare', bookmark > Duration.zero
        ? <String, Object>{'resumeMs': bookmark.inMilliseconds}
        : null);
    _snapshot = const ReadAloudSnapshot(supported: true, active: true);
    RuntimeEventLog.instance.emit('[TTS_PCM_PREPARED]');
  }

  /// Convert generated Float32 PCM to the Android AudioTrack PCM16 format.
  /// Clip before multiplication to prevent overflow/clipping anomalies.
  @override
  void push(Float32List samples, int sampleRate) {
    if (_disposed || samples.isEmpty) return;
    final output = Uint8List(samples.length * 2);
    final view = ByteData.view(output.buffer);
    for (var i = 0; i < samples.length; i++) {
      final v = samples[i].clamp(-1.0, 1.0).toDouble();
      final pcm = (v * (v < 0 ? 32768 : 32767)).round();
      view.setInt16(i * 2, pcm, Endian.little);
    }
    unawaited(_send('append', <String, Object>{
      'pcm': output,
      'sampleRate': sampleRate,
    }).then((_) {
      // The native MethodChannel call completed, not merely a Dart push.
      RuntimeEventLog.instance.emit(
        '[TTS_PCM_APPEND_OK] bytes=${output.length} rate=$sampleRate',
      );
    }).catchError((Object error) {
      RuntimeEventLog.instance.emit(
        '[TTS_PCM_APPEND_FAIL] type=${error.runtimeType}',
      );
    }));
  }

  @override
  Future<void> finishReadAloud() async {
    await _queue;
    final previousFailure = _appendError;
    if (previousFailure != null) {
      throw StateError('PCM native append failed: $previousFailure');
    }
    await _send('finish');
    try {
      final status = await refreshReadAloud();
      RuntimeEventLog.instance.emit(
        '[TTS_PCM_FINISH_STATUS] buffered_ms=${status.buffered.inMilliseconds} '
        'position_ms=${status.position.inMilliseconds} '
        'active=${status.active} playing=${status.playing} '
        'paused=${status.paused} complete=${status.complete}',
      );
    } catch (error) {
      // Diagnostics are best-effort; native audio was already finalized.
      RuntimeEventLog.instance.emit(
        '[TTS_PCM_STATUS_WARN] type=${error.runtimeType}',
      );
    }
  }

  @override
  Future<ReadAloudSnapshot> refreshReadAloud() async {
    if (_disposed) return const ReadAloudSnapshot();
    final raw = await _channel.invokeMapMethod<dynamic, dynamic>('status');
    if (raw != null) {
      _snapshot = ReadAloudSnapshot.fromMap(raw);
    }
    return _snapshot;
  }

  Future<void> _control(String command, [Map<String, Object>? args]) async {
    await _send(command, args);
    await refreshReadAloud();
  }

  @override
  Future<void> pauseReadAloud() => _control('pause');
  @override
  Future<void> resumeReadAloud() => _control('resume');

  @override
  Future<void> seekReadAloud(Duration position) =>
      _control('seek', <String, Object>{'milliseconds': position.inMilliseconds});

  @override
  Future<void> skipReadAloud(Duration offset) =>
      _control('seekRelative', <String, Object>{'milliseconds': offset.inMilliseconds});

  @override
  Future<void> stopReadAloud() async {
    await _send('stop');
    _snapshot = const ReadAloudSnapshot(supported: true);
  }

  @override
  void stop() {
    unawaited(stopReadAloud().catchError((Object _) {}));
  }

  @override
  void dispose() {
    if (_disposed) return;
    unawaited(_send('stop').catchError((Object _) {}).whenComplete(() {
      _disposed = true;
    }));
  }
}

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// One owner isolate keeps the native model warm between phrases and taps.
/// Only ordinary Dart data crosses ports; native ownership never leaves it.
final class KokoroWorker {
  KokoroWorker({void Function(SendPort)? entryPoint})
      : _entryPoint = entryPoint ?? _kokoroWorkerMain;

  final void Function(SendPort) _entryPoint;
  ReceivePort? _events;
  SendPort? _commands;
  Future<void>? _opening;
  Completer<Map<String, Object?>>? _pending;
  Timer? _idle;
  bool _closed = false;

  Future<void> _open() async {
    final ready = Completer<void>();
    final events = ReceivePort();
    _events = events;
    events.listen((dynamic event) {
      if (event is SendPort) {
        _commands = event;
        if (!ready.isCompleted) ready.complete();
        if (_closed) {
          event.send(null);
          events.close();
        }
      } else if (event is Map) {
        final pending = _pending;
        if (pending != null && !pending.isCompleted) {
          if (event['error'] != null) {
            pending.completeError(StateError('Kokoro synthesis failed.'));
          } else {
            pending.complete(Map<String, Object?>.from(event));
          }
        }
      } else {
        final error = StateError('Kokoro worker exited unexpectedly.');
        if (!ready.isCompleted) ready.completeError(error);
        final pending = _pending;
        if (pending != null && !pending.isCompleted) pending.completeError(error);
        close();
      }
    });
    try {
      await Isolate.spawn<SendPort>(
        _entryPoint, events.sendPort,
        onError: events.sendPort, onExit: events.sendPort,
        debugName: 'kokoro-warm-worker',
      );
      await ready.future.timeout(const Duration(seconds: 30));
      if (_closed) {
        _commands?.send(null);
        throw StateError('Kokoro worker closed.');
      }
    } on Object {
      close();
      rethrow;
    }
  }

  bool get isClosed => _closed;

  Future<Map<String, Object?>> generate(Map<String, Object?> request) async {
    if (_closed) throw StateError('Kokoro worker closed.');
    _idle?.cancel();
    await (_opening ??= _open());
    if (_closed) throw StateError('Kokoro worker closed.');
    if (_pending != null) throw StateError('Kokoro worker busy.');
    final pending = Completer<Map<String, Object?>>();
    _pending = pending;
    _commands!.send(request);
    try {
      return await pending.future.timeout(const Duration(seconds: 90));
    } on Object {
      close();
      rethrow;
    } finally {
      _pending = null;
      if (!_closed) _idle = Timer(const Duration(minutes: 2), close);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _idle?.cancel();
    // Queued after synchronous synthesis: free on the owning isolate.
    // Never kill an isolate while it is executing native inference.
    _commands?.send(null);
    if (_commands != null) {
      _events?.close();
    }
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(StateError('Kokoro worker closed.'));
    }
  }
}

void _kokoroWorkerMain(SendPort output) {
  final commands = ReceivePort();
  sherpa.OfflineTts? tts;
  String? identity;
  output.send(commands.sendPort);
  commands.listen((dynamic value) {
    if (value == null) {
      tts?.free();
      tts = null;
      commands.close();
      return;
    }
    try {
      final message = Map<String, Object?>.from(value as Map);
      final key = ['modelPath', 'voicesPath', 'tokensPath', 'dataDir']
          .map((name) => message[name]).join('\u0000');
      final watch = Stopwatch()..start();
      final reused = tts != null && identity == key;
      if (!reused) {
        tts?.free();
        tts = null;
        sherpa.initBindings();
        tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
          model: sherpa.OfflineTtsModelConfig(
            kokoro: sherpa.OfflineTtsKokoroModelConfig(
              model: message['modelPath'] as String,
              voices: message['voicesPath'] as String,
              tokens: message['tokensPath'] as String,
              dataDir: message['dataDir'] as String,
              lang: 'it',
            ),
            numThreads: 1, debug: false, provider: 'cpu',
          ),
          maxNumSenetences: 1,
        ));
        identity = key;
      }
      final loadMs = watch.elapsedMilliseconds;
      final audio = tts!.generateWithConfig(
        text: message['text'] as String,
        config: sherpa.OfflineTtsGenerationConfig(
          sid: message['sid'] as int,
          speed: message['speed'] as double,
          extra: <String, Object>{'lang': message['lang'] as String},
        ),
      );
      output.send(<String, Object?>{
        'samples': Float32List.fromList(audio.samples),
        'sampleRate': audio.sampleRate,
        'loadMs': loadMs,
        'synthesisMs': watch.elapsedMilliseconds - loadMs,
        'reused': reused,
      });
    } on Object {
      tts?.free();
      tts = null;
      identity = null;
      output.send(<String, Object?>{'error': 'synthesis_failed'});
    }
  });
}

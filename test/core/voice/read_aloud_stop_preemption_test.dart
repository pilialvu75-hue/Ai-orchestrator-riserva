import 'dart:async';

import 'package:ai_orchestrator/core/voice/voice_output_service.dart';
import 'package:ai_orchestrator/core/voice/voice_engine.dart';
import 'package:ai_orchestrator/core/voice/read_aloud_transport.dart';
import 'package:flutter_test/flutter_test.dart';

class _SlowReadAloudEngine implements VoiceEngine, ReadAloudVoiceEngine {
  final started = Completer<void>();
  final interrupted = Completer<void>();
  final synthesis = Completer<void>();
  bool stopped = false;

  @override
  bool get supportsRealReadAloudControls => true;
  @override
  ReadAloudSnapshot get readAloudSnapshot =>
      const ReadAloudSnapshot(supported: true, active: true);

  @override
  bool get isSpeaking => started.isCompleted && !stopped;
  @override
  bool get isListening => false;

  @override
  Future<void> speak(String text) async {
    if (!started.isCompleted) started.complete();
    await synthesis.future; // Simulate a very long TTS generation.
  }

  @override
  Future<void> stopSpeaking() async {
    stopped = true;
    if (!interrupted.isCompleted) interrupted.complete();
    if (!synthesis.isCompleted) synthesis.complete();
  }

  @override
  Future<VoiceEngineStatus> inspect() async =>
      VoiceEngineStatus.unsupported(details: 'fake PCM transport');
  @override
  Future<VoiceEngineStatus> initialize() => inspect();
  @override
  Future<void> startListening({
    required VoiceRecognitionResultCallback onResult,
    String localeId = 'it-IT',
  }) async {}
  @override
  Future<void> stopListening() async {}
  @override
  Future<void> dispose() async {}
  @override
  Future<void> pauseReadAloud() async {}
  @override
  Future<void> resumeReadAloud() async {}
  @override
  Future<void> skipReadAloud(Duration offset) async {}
  @override
  Future<void> seekReadAloud(Duration position) async {}
  @override
  Future<ReadAloudSnapshot> refreshReadAloud() async => readAloudSnapshot;
}

class _SwitchingPcmEngine implements VoiceEngine, ReadAloudVoiceEngine {
  final startedFirst = Completer<void>();
  final startedSecond = Completer<void>();
  final releaseFirst = Completer<void>();
  final requests = <String>[];
  var active = false;
  var stops = 0;

  @override
  bool get supportsRealReadAloudControls => true;
  @override
  ReadAloudSnapshot get readAloudSnapshot =>
      ReadAloudSnapshot(supported: true, active: active);
  @override
  bool get isSpeaking => false; // Simulate PCM still buffering.
  @override
  bool get isListening => false;

  @override
  Future<void> speak(String text) async {
    requests.add(text);
    active = true;
    if (requests.length == 1) {
      startedFirst.complete();
      await releaseFirst.future; // Earlier native synthesis still in flight.
    } else if (!startedSecond.isCompleted) {
      startedSecond.complete();
    }
  }

  @override
  Future<void> stopSpeaking() async {
    stops++;
    active = false;
  }
  @override
  Future<ReadAloudSnapshot> refreshReadAloud() async => readAloudSnapshot;
  @override
  Future<VoiceEngineStatus> inspect() async => VoiceEngineStatus.unsupported();
  @override
  Future<VoiceEngineStatus> initialize() => inspect();
  @override
  Future<void> startListening({
    required VoiceRecognitionResultCallback onResult,
    String localeId = 'it-IT',
  }) async {}
  @override
  Future<void> stopListening() async {}
  @override
  Future<void> dispose() async {}
  @override
  Future<void> pauseReadAloud() async {}
  @override
  Future<void> resumeReadAloud() async {}
  @override
  Future<void> skipReadAloud(Duration offset) async {}
  @override
  Future<void> seekReadAloud(Duration position) async {}
}

void main() {
  test('switching messages preempts PCM queue before synthesis ends',
      () async {
    final engine = _SwitchingPcmEngine();
    final output = VoiceOutputService(engine: engine);
    final first = output.speak('Prima risposta molto lunga');
    await engine.startedFirst.future;
    final second = output.speak('Seconda risposta');

    // The old operation queue blocked this until releaseFirst completed.
    await engine.startedSecond.future.timeout(const Duration(seconds: 2));
    expect(engine.requests, ['Prima risposta molto lunga', 'Seconda risposta']);
    expect(engine.stops, 1);

    engine.releaseFirst.complete();
    await Future.wait([first, second]);
  });

  test('same-message tap stops an active PCM session without restarting',
      () async {
    final engine = _SwitchingPcmEngine();
    final output = VoiceOutputService(engine: engine);
    final first = output.speak('Messaggio corrente');
    await engine.startedFirst.future;
    await output.speak('Messaggio corrente');
    expect(engine.stops, 1);
    expect(engine.requests, ['Messaggio corrente']);
    engine.releaseFirst.complete();
    await first;
  });

  test('new explicit play after audio-focus loss is not a stale toggle',
      () async {
    final engine = _SwitchingPcmEngine();
    final output = VoiceOutputService(engine: engine);
    final first = output.speak('Riprendi dopo YouTube');
    await engine.startedFirst.future;
    engine.active = false; // Permanent loss closed the native session.
    engine.releaseFirst.complete();
    await first;

    await output.speak('Riprendi dopo YouTube');
    expect(engine.requests,
        ['Riprendi dopo YouTube', 'Riprendi dopo YouTube']);
  });
  test('stop does not wait for long PCM speech generation queue', () async {
    final engine = _SlowReadAloudEngine();
    final service = VoiceOutputService(engine: engine);
    final speaking = service.speak('Una risposta lunga da leggere...');
    await engine.started.future;

    // This must complete even though the original speak() Future has not
    // completed: old behavior delayed Stop until the end of a long answer.
    final stopping = service.stopSpeaking();
    await engine.interrupted.future;
    await stopping;
    await speaking;
    expect(engine.stopped, true);
  });
}

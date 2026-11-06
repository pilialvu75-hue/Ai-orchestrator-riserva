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

void main() {
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

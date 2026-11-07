import 'dart:async';

import 'package:ai_orchestrator/core/voice/voice_engine.dart';
import 'package:ai_orchestrator/core/voice/voice_input_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryEngine implements VoiceEngine, VoiceRecognitionMemoryReclaimer {
  int initCalls = 0;
  int stopCalls = 0;
  int startCalls = 0;
  int releaseCalls = 0;
  bool listening = false;
  Completer<void>? stopGate;
  Completer<bool>? releaseGate;
  bool releaseSucceeds = true;

  @override
  bool get isListening => listening;

  @override
  Future<VoiceEngineStatus> initialize() async {
    initCalls++;
    return const VoiceEngineStatus(
      engineId: 'fake',
      supportedPlatform: true,
      nativeLibrariesLoaded: true,
      microphonePermissionGranted: true,
      audioSessionReady: true,
      speakerOutputReady: false,
      initialized: true,
      offlineAsrAvailable: true,
      offlineTtsAvailable: false,
    );
  }

  @override
  Future<void> startListening({
    required VoiceRecognitionResultCallback onResult,
    String localeId = 'it-IT',
  }) async {
    startCalls++;
    listening = true;
  }

  @override
  Future<void> stopListening() async {
    stopCalls++;
    final gate = stopGate;
    if (gate != null) await gate.future;
    listening = false;
  }

  @override
  Future<bool> releaseRecognitionMemoryForInference() async {
    if (listening) throw StateError('Native microphone still active');
    releaseCalls++;
    final gate = releaseGate;
    if (gate != null) return gate.future;
    return releaseSucceeds;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Windows exercises the service without requesting native Android
    // microphone permission. The real handoff gate is Android-only in UI.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('dictation handoff closes mic before native ASR release and reinitializes',
      () async {
    final engine = _MemoryEngine();
    final service = VoiceInputService(engine: engine);
    await service.startListening(onResult: (_, __) {});
    expect(engine.initCalls, 1);
    expect(service.isListening, isTrue);

    expect(await service.releaseRecognitionMemoryForInference(), isTrue);
    expect(engine.releaseCalls, 1);
    expect(engine.stopCalls, 1);
    expect(service.isListening, isFalse);

    await service.startListening(onResult: (_, __) {});
    expect(engine.initCalls, 2);
    expect(engine.startCalls, 2);
    expect(service.isListening, isTrue);
    await service.stopListening();
  });

  test('duplicate stops are serialized before another microphone start',
      () async {
    final engine = _MemoryEngine();
    final service = VoiceInputService(engine: engine);
    await service.startListening(onResult: (_, __) {});
    engine.stopGate = Completer<void>();

    final firstStop = service.stopListening();
    final secondStop = service.stopListening();
    expect(engine.stopCalls, 1);

    final nextStart = service.startListening(onResult: (_, __) {});
    await Future<void>.delayed(Duration.zero);
    expect(engine.startCalls, 1);
    engine.stopGate!.complete();

    await Future.wait<void>([firstStop, secondStop, nextStart]);
    expect(engine.stopCalls, 1);
    expect(engine.startCalls, 2);
    expect(engine.listening, isTrue);
    engine.stopGate = null;
    await service.stopListening();
  });

  test('parallel releases coalesce and next mic tap waits for native free',
      () async {
    final engine = _MemoryEngine()..releaseGate = Completer<bool>();
    final service = VoiceInputService(engine: engine);
    await service.startListening(onResult: (_, __) {});

    final firstRelease = service.releaseRecognitionMemoryForInference();
    final secondRelease = service.releaseRecognitionMemoryForInference();
    await Future<void>.delayed(Duration.zero);
    expect(engine.stopCalls, 1);
    expect(engine.releaseCalls, 1);
    expect(engine.listening, isFalse);

    final secondDictation = service.startListening(onResult: (_, __) {});
    await Future<void>.delayed(Duration.zero);
    // No stale recognizer may be reused while native free is unfinished.
    expect(engine.initCalls, 1);
    expect(engine.startCalls, 1);

    engine.releaseGate!.complete(true);
    expect(await firstRelease, isTrue);
    expect(await secondRelease, isTrue);
    await secondDictation;
    expect(engine.releaseCalls, 1);
    expect(engine.initCalls, 2);
    expect(engine.startCalls, 2);
    engine.releaseGate = null;
    await service.stopListening();
  });

  test('a failed native release still forces a fresh input initialization',
      () async {
    final engine = _MemoryEngine()..releaseSucceeds = false;
    final service = VoiceInputService(engine: engine);
    await service.startListening(onResult: (_, __) {});
    expect(await service.releaseRecognitionMemoryForInference(), isFalse);
    await service.startListening(onResult: (_, __) {});
    expect(engine.initCalls, 2);
    await service.stopListening();
  });
}

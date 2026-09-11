import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/core/voice/isolated_kokoro_voice_engine.dart';
import 'package:ai_orchestrator/core/voice/voice_engine.dart';

void main() {
  const assets = <String, String>{
    'model': '/test/model.onnx',
    'voices': '/test/voices.bin',
    'tokens': '/test/tokens.txt',
    'data': '/test/espeak-ng-data',
  };

  test('routes Kokoro generation through injected background runner', () async {
    final delegate = _FakeVoiceEngine();
    final sink = _FakeTtsAudioSink();
    KokoroTtsGenerationRequest? captured;

    final engine = IsolatedKokoroVoiceEngine(
      delegate: delegate,
      languageCode: () => 'it-IT',
      assetsProvider: () async => assets,
      audioSink: sink,
      generationRunner: (request) async {
        captured = request;
        return KokoroTtsGeneratedAudio(
          samples: Float32List.fromList(<double>[0.1, -0.1, 0.0]),
          sampleRate: 22050,
        );
      },
    );

    await engine.speak('  Ciao Roberto  ');

    expect(delegate.speakCalls, 0);
    expect(captured, isNotNull);
    expect(captured!.text, 'Ciao Roberto');
    expect(captured!.lang, 'it');
    expect(captured!.sid, 35);
    expect(captured!.speed, 1.0);
    expect(captured!.modelPath, assets['model']);
    expect(sink.pushCount, 1);
    expect(sink.lastSampleRate, 22050);
    expect(sink.lastSamples, hasLength(3));
  });

  test('does not start a second Kokoro generation while one is active', () async {
    final delegate = _FakeVoiceEngine();
    final sink = _FakeTtsAudioSink();
    final started = Completer<void>();
    final finish = Completer<KokoroTtsGeneratedAudio>();
    var runnerCalls = 0;

    final engine = IsolatedKokoroVoiceEngine(
      delegate: delegate,
      assetsProvider: () async => assets,
      audioSink: sink,
      generationRunner: (request) {
        runnerCalls++;
        if (!started.isCompleted) started.complete();
        return finish.future;
      },
    );

    final first = engine.speak('prima richiesta');
    await started.future;

    await engine.speak('seconda richiesta');
    expect(runnerCalls, 1);

    finish.complete(
      KokoroTtsGeneratedAudio(
        samples: Float32List.fromList(<double>[0.1, 0.2]),
        sampleRate: 22050,
      ),
    );
    await first;

    expect(sink.pushCount, 1);
  });

  test('stop invalidates audio returned later by the worker', () async {
    final delegate = _FakeVoiceEngine();
    final sink = _FakeTtsAudioSink();
    final started = Completer<void>();
    final finish = Completer<KokoroTtsGeneratedAudio>();

    final engine = IsolatedKokoroVoiceEngine(
      delegate: delegate,
      assetsProvider: () async => assets,
      audioSink: sink,
      generationRunner: (request) {
        if (!started.isCompleted) started.complete();
        return finish.future;
      },
    );

    final speaking = engine.speak('testo lungo');
    await started.future;

    await engine.stopSpeaking();
    expect(sink.stopCount, 1);

    finish.complete(
      KokoroTtsGeneratedAudio(
        samples: Float32List.fromList(<double>[0.1, 0.2]),
        sampleRate: 22050,
      ),
    );
    await speaking;

    expect(sink.pushCount, 0);
  });

  test('rapid taps during asset preparation launch only one worker', () async {
    final prepared = Completer<Map<String, String>?>();
    var runnerCalls = 0;
    final engine = IsolatedKokoroVoiceEngine(
      delegate: _FakeVoiceEngine(),
      assetsProvider: () => prepared.future,
      audioSink: _FakeTtsAudioSink(),
      generationRunner: (_) async {
        runnerCalls++;
        return KokoroTtsGeneratedAudio(
          samples: Float32List.fromList([0.1, -0.1]), sampleRate: 24000,
        );
      },
    );
    final first = engine.speak('prima');
    await engine.speak('seconda');
    prepared.complete(assets);
    await first;
    expect(runnerCalls, 1);
  });

  test('stop during preparation prevents synthesis and allows the next tap', () async {
    final prepared = Completer<Map<String, String>?>();
    var runnerCalls = 0;
    final sink = _FakeTtsAudioSink();
    final engine = IsolatedKokoroVoiceEngine(
      delegate: _FakeVoiceEngine(),
      assetsProvider: () => prepared.future,
      audioSink: sink,
      generationRunner: (_) async {
        runnerCalls++;
        return KokoroTtsGeneratedAudio(
          samples: Float32List.fromList([0.1, -0.1]), sampleRate: 24000,
        );
      },
    );
    final first = engine.speak('annulla questa');
    await engine.stopSpeaking();
    prepared.complete(assets);
    await first;
    expect(runnerCalls, 0);
    expect(sink.pushCount, 0);
    await engine.speak('nuova lettura');
    expect(runnerCalls, 1);
    expect(sink.pushCount, 1);
  });

  test('inspect exposes Kokoro output readiness without native TTS init', () async {
    final delegate = _FakeVoiceEngine();
    final engine = IsolatedKokoroVoiceEngine(
      delegate: delegate,
      assetsProvider: () async => assets,
      audioSink: _FakeTtsAudioSink(),
      generationRunner: (request) async => KokoroTtsGeneratedAudio(
        samples: Float32List.fromList(<double>[0.1]),
        sampleRate: 22050,
      ),
    );

    final status = await engine.inspect();

    expect(status.speakerOutputReady, isTrue);
    expect(status.offlineTtsAvailable, isTrue);
    expect(delegate.speakCalls, 0);
  });
}

final class _FakeVoiceEngine implements VoiceEngine {
  int speakCalls = 0;
  bool listening = false;
  bool speaking = false;

  VoiceEngineStatus status = const VoiceEngineStatus(
    engineId: sherpaOnnxEngineId,
    supportedPlatform: true,
    nativeLibrariesLoaded: true,
    microphonePermissionGranted: true,
    audioSessionReady: true,
    speakerOutputReady: false,
    initialized: true,
    offlineAsrAvailable: true,
    offlineTtsAvailable: false,
    speechRate: 1.0,
  );

  @override
  bool get isListening => listening;

  @override
  bool get isSpeaking => speaking;

  @override
  Future<VoiceEngineStatus> inspect() async => status;

  @override
  Future<VoiceEngineStatus> initialize() async => status;

  @override
  Future<void> startListening({
    required VoiceRecognitionResultCallback onResult,
    String localeId = 'it-IT',
  }) async {
    listening = true;
  }

  @override
  Future<void> stopListening() async {
    listening = false;
  }

  @override
  Future<void> speak(String text) async {
    speakCalls++;
    speaking = true;
  }

  @override
  Future<void> stopSpeaking() async {
    speaking = false;
  }

  @override
  Future<void> dispose() async {
    listening = false;
    speaking = false;
  }
}

final class _FakeTtsAudioSink implements TtsAudioSink {
  int pushCount = 0;
  int stopCount = 0;
  int disposeCount = 0;
  Float32List? lastSamples;
  int? lastSampleRate;

  @override
  bool get isPlaying => pushCount > 0 && stopCount == 0;

  @override
  void push(Float32List samples, int sampleRate) {
    pushCount++;
    lastSamples = samples;
    lastSampleRate = sampleRate;
  }

  @override
  void stop() {
    stopCount++;
  }

  @override
  void dispose() {
    disposeCount++;
  }
}

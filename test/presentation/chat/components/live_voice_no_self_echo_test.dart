import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:ai_orchestrator/core/voice/voice_engine.dart';
import 'package:ai_orchestrator/core/voice/voice_loop_manager.dart';
import 'package:ai_orchestrator/core/voice/voice_model_downloader.dart';
import 'package:ai_orchestrator/presentation/chat/components/live_voice_overlay.dart';

class _FakeLoop extends Mock implements VoiceLoopManager {
  int turns = 0;

  @override
  bool get isSessionActive => false;

  @override
  Future<void> startLiveSession({
    String? modelPath,
    String? modelId,
    String? systemPrompt,
    Future<void> Function(String text)? onUserTranscript,
    Future<void> Function(String text)? onAssistantTranscript,
    void Function(String text, bool isFinal)? onSubtitle,
    void Function(String error)? onError,
  }) async {
    turns++;
  }

  @override
  Future<void> stopLiveSession() async {}
}

class _ReadyEngine extends Mock implements VoiceEngine {
  @override
  bool get isListening => false;

  @override
  bool get isSpeaking => false;

  @override
  Future<VoiceEngineStatus> initialize() async => const VoiceEngineStatus(
        engineId: sherpaOnnxEngineId,
        supportedPlatform: true,
        nativeLibrariesLoaded: true,
        microphonePermissionGranted: true,
        audioSessionReady: true,
        speakerOutputReady: true,
        initialized: true,
        offlineAsrAvailable: true,
        offlineTtsAvailable: true,
      );
}

class _Downloader extends Mock implements VoiceModelDownloader {}

void main() {
  testWidgets('Live does not self-trigger a second turn after speaking',
      (tester) async {
    final loop = _FakeLoop();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LiveVoiceOverlay(
          voiceLoopManager: loop,
          voiceEngine: _ReadyEngine(),
          voiceModelDownloader: _Downloader(),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(loop.turns, 1);
    expect(find.text("Ascolta un'altra domanda"), findsOneWidget);

    // Time passing and status polling must not open the microphone again.
    await tester.pump(const Duration(seconds: 2));
    expect(loop.turns, 1);

    await tester.tap(find.text("Ascolta un'altra domanda"));
    await tester.pump();
    expect(loop.turns, 2);
  });
}

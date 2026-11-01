import 'package:ai_orchestrator/core/voice/voice_engine.dart';
import 'package:ai_orchestrator/core/voice/voice_output_service.dart';
import 'package:ai_orchestrator/features/chat/presentation/controllers/chat_speech_playback_controller.dart';
import 'package:ai_orchestrator/features/chat/presentation/widgets/chat_speech_playback_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeVoiceEngine implements VoiceEngine {
  bool speaking = false;
  final played = <String>[];
  int stopped = 0;

  @override
  bool get isSpeaking => speaking;
  @override
  bool get isListening => false;
  @override
  Future<VoiceEngineStatus> inspect() async => VoiceEngineStatus.unsupported();
  @override
  Future<VoiceEngineStatus> initialize() async =>
      VoiceEngineStatus.unsupported();
  @override
  Future<void> startListening({
    required VoiceRecognitionResultCallback onResult,
    String localeId = 'it-IT',
  }) async {}
  @override
  Future<void> stopListening() async {}
  @override
  Future<void> speak(String text) async {
    played.add(text);
    speaking = true;
  }
  @override
  Future<void> stopSpeaking() async {
    stopped++;
    speaking = false;
  }
  @override
  Future<void> dispose() async {
    speaking = false;
  }
}

void main() {
  test('splits IT/FR/EN sentences for meaningful rewind points', () {
    expect(
      ChatSpeechPlaybackController.splitPhrases(
          'Buongiorno. Bonjour! How are you?'),
      ['Buongiorno.', 'Bonjour!', 'How are you?'],
    );
    expect(ChatSpeechPlaybackController.splitPhrases(''), isEmpty);
  });

  testWidgets('pause, previous, next, stop and close control actual TTS',
      (tester) async {
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final engine = _FakeVoiceEngine();
    final controller =
        ChatSpeechPlaybackController(VoiceOutputService(engine: engine));
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => controller.visible
              ? ChatSpeechPlaybackBar(controller: controller)
              : const SizedBox.shrink(),
        ),
      ),
    ));

    controller.start('Prima frase. Seconda frase. Terza frase.');
    await tester.pump();
    expect(find.byTooltip('Pausa'), findsOneWidget);
    expect(controller.phraseNumber, 1);
    await tester.tap(find.byTooltip('Pausa'));
    await tester.pump();
    expect(controller.state, SpeechPlaybackState.paused);
    expect(engine.stopped, greaterThan(0));

    await tester.tap(find.byTooltip('Riprendi dalla frase'));
    await tester.pump();
    expect(controller.phraseNumber, 1);

    controller.next();
    await tester.pump();
    expect(controller.phraseNumber, 2);
    controller.previous();
    await tester.pump();
    expect(controller.phraseNumber, 1);

    await tester.tap(find.byTooltip('Interrompi'));
    await tester.pump();
    expect(controller.state, SpeechPlaybackState.stopped);
    expect(controller.visible, isTrue);

    await tester.tap(find.byTooltip('Chiudi ascolto'));
    await tester.pump();
    expect(controller.visible, isFalse);
    expect(find.byType(ChatSpeechPlaybackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('audio toolbar stays compact without a phone overflow',
      (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final engine = _FakeVoiceEngine();
    final controller =
        ChatSpeechPlaybackController(VoiceOutputService(engine: engine));
    addTearDown(controller.dispose);
    controller.start('Prova.');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatSpeechPlaybackBar(controller: controller),
      ),
    ));
    expect(find.byTooltip('Chiudi ascolto'), findsOneWidget);
    expect(find.byTooltip('Torna indietro di una frase'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

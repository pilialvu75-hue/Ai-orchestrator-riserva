import 'package:ai_orchestrator/core/voice/read_aloud_transport.dart';
import 'package:ai_orchestrator/core/voice/voice_engine.dart';
import 'package:ai_orchestrator/core/voice/voice_output_service.dart';
import 'package:ai_orchestrator/presentation/chat/controllers/chat_audio_playback_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class _NoopVoiceEngine implements VoiceEngine {
  @override
  bool get isSpeaking => false;
  @override
  bool get isListening => false;
  @override
  Future<void> speak(String text) async {}
  @override
  Future<void> stopSpeaking() async {}
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
  Future<VoiceEngineStatus> initialize() async =>
      VoiceEngineStatus.unsupported();
  @override
  Future<VoiceEngineStatus> inspect() async =>
      VoiceEngineStatus.unsupported();
}

class _FakeOutput extends VoiceOutputService {
  _FakeOutput() : super(engine: _NoopVoiceEngine());

  ReadAloudSnapshot current =
      const ReadAloudSnapshot(supported: true, active: true);

  @override
  bool get supportsRealReadAloudControls => true;
  @override
  ReadAloudSnapshot get readAloudSnapshot => current;
  @override
  Future<ReadAloudSnapshot> refreshReadAloud() async => current;
  @override
  Future<void> speak(String text) async {}
}

void main() {
  testWidgets('auto-finished service dismisses dead resume controls',
      (tester) async {
    final output = _FakeOutput();
    final controller = ChatAudioPlaybackController(output: output);
    await controller.play('Testo sintetizzato in una sessione foreground');
    expect(controller.isOpen, true);

    await tester.pump(const Duration(milliseconds: 260));
    expect(controller.isOpen, true);

    // Native service has drained PCM and removed itself; Android status now
    // reports no session, not an inactive yet-seekable MediaSession.
    output.current = const ReadAloudSnapshot(supported: true);
    await tester.pump(const Duration(milliseconds: 260));
    expect(controller.isOpen, false);
    expect(controller.isPlaying, false);
    expect(controller.measuredPlayback.position, Duration.zero);
  });

  testWidgets('explicit pause keeps foreground player available',
      (tester) async {
    final output = _FakeOutput();
    final controller = ChatAudioPlaybackController(output: output);
    await controller.play('Una lettura da riprendere dopo trenta secondi');
    output.current = const ReadAloudSnapshot(
      supported: true,
      active: true,
      paused: true,
      position: Duration(seconds: 20),
      buffered: Duration(seconds: 60),
    );
    await tester.pump(const Duration(milliseconds: 260));
    expect(controller.isOpen, true);
    expect(controller.isPaused, true);
    expect(controller.measuredPlayback.position, const Duration(seconds: 20));
    // Close while still active, to avoid fake periodic tasks leaking.
    controller.close();
    await tester.pump();
  });
}

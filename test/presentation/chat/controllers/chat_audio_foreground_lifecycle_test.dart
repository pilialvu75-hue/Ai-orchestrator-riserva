import 'dart:async';

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

  Completer<void>? pendingSpeech;
  Duration? resumeRequested;
  String? resumedText;

  @override
  bool get supportsRealReadAloudControls => true;
  @override
  ReadAloudSnapshot get readAloudSnapshot => current;
  @override
  Future<ReadAloudSnapshot> refreshReadAloud() async => current;
  @override
  Future<void> speak(String text) async {
    if (pendingSpeech != null) await pendingSpeech!.future;
  }

  @override
  Future<void> speakFromPosition(String text, Duration position) async {
    resumedText = text;
    resumeRequested = position;
  }
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

  testWidgets('permanent audio focus loss clears busy foreground player',
      (tester) async {
    final output = _FakeOutput();
    output.pendingSpeech = Completer<void>();
    final controller = ChatAudioPlaybackController(output: output);
    final speaking = controller.play('Sintesi ancora in corso');
    await tester.pump(const Duration(milliseconds: 260));
    expect(controller.isOpen, true);
    expect(controller.isBusy, true);
    expect(controller.measuredPlayback.active, true);

    // YouTube has received permanent focus; the native MediaSession is gone.
    output.current = const ReadAloudSnapshot(supported: true);
    await tester.pump(const Duration(milliseconds: 260));
    expect(controller.isOpen, false);
    expect(controller.isBusy, false);
    expect(controller.isPlaying, false);

    output.pendingSpeech!.complete();
    await speaking;
    expect(controller.isOpen, false);
  });

  testWidgets('external focus loss bookmarks only matching explicit replay',
      (tester) async {
    final output = _FakeOutput();
    final controller = ChatAudioPlaybackController(output: output);
    const text = 'Risposta ancora lunga da ascoltare';
    await controller.play(text);

    output.current = const ReadAloudSnapshot(
      supported: true,
      active: true,
      playing: true,
      position: Duration(seconds: 23),
      buffered: Duration(seconds: 45),
      complete: false,
    );
    await tester.pump(const Duration(milliseconds: 260));
    expect(controller.measuredPlayback.position, const Duration(seconds: 23));

    output.current = const ReadAloudSnapshot(
      supported: true,
      terminatedByFocusLoss: true,
      position: Duration(seconds: 23),
      buffered: Duration(seconds: 45),
    );
    await tester.pump(const Duration(milliseconds: 260));
    expect(controller.isOpen, false);
    await controller.play(text);
    expect(output.resumeRequested, const Duration(seconds: 23));
    expect(output.resumedText, text);
    controller.close();
    await tester.pump();
  });

  testWidgets('different message never reuses an audio-focus bookmark',
      (tester) async {
    final output = _FakeOutput();
    final controller = ChatAudioPlaybackController(output: output);
    await controller.play('Prima risposta');
    output.current = const ReadAloudSnapshot(
      supported: true,
      active: true,
      position: Duration(seconds: 17),
      buffered: Duration(seconds: 25),
    );
    await tester.pump(const Duration(milliseconds: 260));
    output.current = const ReadAloudSnapshot(
      supported: true,
      terminatedByFocusLoss: true,
      position: Duration(seconds: 17),
      buffered: Duration(seconds: 25),
    );
    await tester.pump(const Duration(milliseconds: 260));
    await controller.play('Seconda risposta');
    expect(output.resumeRequested, isNull);
    controller.close();
    await tester.pump();
  });

  testWidgets('manual Stop does not create an audio-focus bookmark',
      (tester) async {
    final output = _FakeOutput();
    final controller = ChatAudioPlaybackController(output: output);
    await controller.play('Lettura da fermare');
    output.current = const ReadAloudSnapshot(
      supported: true,
      active: true,
      position: Duration(seconds: 13),
      buffered: Duration(seconds: 30),
    );
    await tester.pump(const Duration(milliseconds: 260));
    output.current = const ReadAloudSnapshot(
      supported: true,
      position: Duration(seconds: 13),
      buffered: Duration(seconds: 30),
    );
    await tester.pump(const Duration(milliseconds: 260));
    await controller.play('Lettura da fermare');
    expect(output.resumeRequested, isNull);
    controller.close();
    await tester.pump();
  });

  testWidgets('tap on return recovers focus loss even before poll',
      (tester) async {
    final output = _FakeOutput();
    final controller = ChatAudioPlaybackController(output: output);
    const text = 'Ripresa immediata dopo YouTube';
    await controller.play(text);
    output.current = const ReadAloudSnapshot(
      supported: true,
      active: true,
      playing: true,
      position: Duration(seconds: 21),
      buffered: Duration(seconds: 35),
    );
    await tester.pump(const Duration(milliseconds: 260));

    // No subsequent poll occurred: the next tap must preflight native state.
    output.current = const ReadAloudSnapshot(
      supported: true,
      terminatedByFocusLoss: true,
      position: Duration(seconds: 22),
      buffered: Duration(seconds: 35),
    );
    await controller.play(text);
    expect(output.resumeRequested, const Duration(seconds: 22));
    controller.close();
    await tester.pump();
  });

  testWidgets('bookmark rebuilding keeps player busy until target is ready',
      (tester) async {
    final output = _FakeOutput();
    final controller = ChatAudioPlaybackController(output: output);
    await controller.play('Riascolto con segnalibro');
    output.current = const ReadAloudSnapshot(
      supported: true,
      active: true,
      rebuildingBookmark: true,
      buffered: Duration(seconds: 12),
    );
    await tester.pump(const Duration(milliseconds: 260));
    expect(controller.isBusy, true);
    expect(controller.measuredPlayback.rebuildingBookmark, true);

    output.current = const ReadAloudSnapshot(
      supported: true,
      active: true,
      playing: true,
      buffered: Duration(seconds: 30),
      position: Duration(seconds: 20),
    );
    await tester.pump(const Duration(milliseconds: 260));
    expect(controller.isBusy, false);
    expect(controller.isPlaying, true);
    controller.close();
    await tester.pump();
  });

  testWidgets('natural completion does not create resume bookmark',
      (tester) async {
    final output = _FakeOutput();
    final controller = ChatAudioPlaybackController(output: output);
    await controller.play('Lettura conclusa');
    output.current = const ReadAloudSnapshot(
      supported: true,
      active: true,
      complete: true,
      position: Duration(seconds: 20),
      buffered: Duration(seconds: 20),
    );
    await tester.pump(const Duration(milliseconds: 260));
    output.current = const ReadAloudSnapshot(supported: true);
    await tester.pump(const Duration(milliseconds: 260));
    await controller.play('Lettura conclusa');
    expect(output.resumeRequested, isNull);
    controller.close();
    await tester.pump();
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

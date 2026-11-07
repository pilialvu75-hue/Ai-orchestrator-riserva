import 'package:ai_orchestrator/core/voice/voice_engine.dart';
import 'package:ai_orchestrator/core/voice/voice_input_service.dart';
import 'package:ai_orchestrator/features/voice/presentation/widgets/voice_input_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _UnusedVoiceEngine implements VoiceEngine {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeVoiceInputService extends VoiceInputService {
  _FakeVoiceInputService() : super(engine: _UnusedVoiceEngine());

  VoiceRecognitionResultCallback? callback;
  bool listening = false;
  int stopCalls = 0;

  @override
  bool get isListening => listening;

  @override
  Future<void> startListening({
    required VoiceRecognitionResultCallback onResult,
    String localeId = 'it-IT',
  }) async {
    listening = true;
    callback = onResult;
  }

  @override
  Future<void> stopListening() async {
    stopCalls++;
    listening = false;
  }
}

void main() {
  testWidgets('final dictation tears down native recorder after callback',
      (tester) async {
    final input = _FakeVoiceInputService();
    final received = <String>[];
    var stopped = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VoiceInputButton(
          voiceInputService: input,
          onResult: (text, isFinal) => received.add('$text:$isFinal'),
          onRecordingStopped: () => stopped++,
        ),
      ),
    ));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    expect(input.listening, isTrue);
    input.callback!.call('Frase dettata', true);
    // Teardown happens in the next event turn, after Sherpa's onResult
    // callback has unwound and native recognizer.reset has returned.
    await tester.pump(const Duration(milliseconds: 10));
    expect(input.stopCalls, 1);
    expect(input.listening, isFalse);
    expect(received, ['Frase dettata:true']);
    expect(stopped, 1);
  });

  testWidgets('leaving chat during recording closes the microphone',
      (tester) async {
    final input = _FakeVoiceInputService();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: VoiceInputButton(
        voiceInputService: input,
        onResult: (_, __) {},
      )),
    ));
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    expect(input.listening, isTrue);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Text('Another route')),
    ));
    await tester.pump();
    expect(input.stopCalls, 1);
    expect(input.listening, isFalse);
  });
}

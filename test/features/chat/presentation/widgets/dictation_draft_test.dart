import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/features/chat/presentation/widgets/dictation_draft.dart';

void main() {
  group('DictationDraftBuffer', () {
    test('preserves typed text through partial and final recognition', () {
      final buffer = DictationDraftBuffer()..begin('Teiera rossa');
      final interim = buffer.accept(
        currentText: 'Teiera rossa',
        transcript: 'costa',
        isFinal: false,
      );
      expect(interim, 'Teiera rossa costa');
      final result = buffer.accept(
        currentText: interim,
        transcript: 'costa 24 euro',
        isFinal: true,
      );
      expect(result, 'Teiera rossa costa 24 euro');
    });

    test('new recording appends after an interim-only stop', () {
      final buffer = DictationDraftBuffer()..begin('Ciao');
      final partial = buffer.accept(
        currentText: 'Ciao',
        transcript: 'mondo',
        isFinal: false,
      );
      buffer.stop(partial);
      buffer.begin(partial);
      expect(
        buffer.accept(
          currentText: partial,
          transcript: 'di nuovo',
          isFinal: true,
        ),
        'Ciao mondo di nuovo',
      );
    });

    test('keeps manual edits made during recognition', () {
      final buffer = DictationDraftBuffer()..begin('Prima');
      buffer.accept(
        currentText: 'Prima',
        transcript: 'test',
        isFinal: false,
      );
      expect(
        buffer.accept(
          currentText: 'Testo corretto',
          transcript: 'finale',
          isFinal: true,
        ),
        'Testo corretto finale',
      );
    });

    test('does not add unnecessary spacing', () {
      final buffer = DictationDraftBuffer()..begin('');
      expect(
        buffer.accept(
          currentText: '',
          transcript: 'ciao',
          isFinal: true,
        ),
        'ciao',
      );
      buffer.begin('Riga ');
      expect(
        buffer.accept(
          currentText: 'Riga ',
          transcript: 'due',
          isFinal: true,
        ),
        'Riga due',
      );
    });
  });
}

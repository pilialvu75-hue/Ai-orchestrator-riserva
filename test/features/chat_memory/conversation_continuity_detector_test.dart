import 'package:ai_orchestrator/features/chat_memory/conversation_continuity_detector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ConversationContinuityDetector', () {
    test('detects explicit prior-conversation references', () {
      expect(
        ConversationContinuityDetector.needsDeepHistory(
          'Fai come abbiamo deciso per il Cantiere.',
        ),
        isTrue,
      );
      expect(
        ConversationContinuityDetector.needsDeepHistory(
          'Do you remember what we agreed before?',
        ),
        isTrue,
      );
      expect(
        ConversationContinuityDetector.needsDeepHistory(
          'Tu te souviens de notre discussion précédente ?',
        ),
        isTrue,
      );
      expect(
        ConversationContinuityDetector.needsDeepHistory(
          '¿Te acuerdas de lo que hablamos?',
        ),
        isTrue,
      );
    });

    test('does not expand history for ordinary sequencing or continue', () {
      expect(
        ConversationContinuityDetector.needsDeepHistory(
          'Prima fai il backup, poi aggiorna.',
        ),
        isFalse,
      );
      expect(
        ConversationContinuityDetector.needsDeepHistory('Continua.'),
        isFalse,
      );
      expect(
        ConversationContinuityDetector.needsDeepHistory(
          'Spiegami la funzione previousValue.',
        ),
        isFalse,
      );
    });
  });
}

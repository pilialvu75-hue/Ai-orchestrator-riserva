import 'package:ai_orchestrator/features/chat_memory/chronological_recall_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChronologicalRecallPolicy', () {
    test('recognizes explicit references to earlier conversation', () {
      expect(
        ChronologicalRecallPolicy.shouldRecall('Come avevamo deciso?'),
        isTrue,
      );
      expect(
        ChronologicalRecallPolicy.shouldRecall('As we discussed earlier'),
        isTrue,
      );
      expect(
        ChronologicalRecallPolicy.shouldRecall('Tu te souviens ?'),
        isTrue,
      );
      expect(
        ChronologicalRecallPolicy.shouldRecall('Como decidimos'),
        isTrue,
      );
    });

    test('does not deep-recall for ordinary continuation or temporal words', () {
      expect(ChronologicalRecallPolicy.shouldRecall('Continua.'), isFalse);
      expect(ChronologicalRecallPolicy.shouldRecall('Prosegui'), isFalse);
      expect(
        ChronologicalRecallPolicy.shouldRecall('Quello di prima'),
        isFalse,
      );
      expect(
        ChronologicalRecallPolicy.shouldRecall('The previous one'),
        isFalse,
      );
      expect(
        ChronologicalRecallPolicy.shouldRecall("Celui d'avant"),
        isFalse,
      );
      expect(
        ChronologicalRecallPolicy.shouldRecall('El de antes'),
        isFalse,
      );
      expect(
        ChronologicalRecallPolicy.shouldRecall(
          'Prima di iniziare spiegami la fotosintesi',
        ),
        isFalse,
      );
      expect(
        ChronologicalRecallPolicy.shouldRecall(
          'Qual è la versione precedente di Android?',
        ),
        isFalse,
      );
      expect(
        ChronologicalRecallPolicy.shouldRecall(
          'Explain the previous Android release',
        ),
        isFalse,
      );
    });

    test('caps recall to two complete exchanges', () {
      expect(ChronologicalRecallPolicy.maxRecalledExchanges, 2);
    });
  });
}

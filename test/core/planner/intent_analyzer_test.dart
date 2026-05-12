import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/orchestrator/intent_analyzer.dart';
import 'package:ai_orchestrator/core/orchestrator/task_type.dart';

void main() {
  const analyzer = IntentAnalyzer();

  group('IntentAnalyzer – existing command keywords', () {
    test('apri → command', () {
      expect(analyzer.analyze('apri la fotocamera'), TaskType.command);
    });

    test('chiama → command', () {
      expect(analyzer.analyze('chiama Mario'), TaskType.command);
    });

    test('lancia → command', () {
      expect(analyzer.analyze('lancia l\'app'), TaskType.command);
    });
  });

  group('IntentAnalyzer – planning keywords', () {
    test('pianifica → plan', () {
      expect(analyzer.analyze('pianifica il progetto'), TaskType.plan);
    });

    test('decomponi → plan', () {
      expect(analyzer.analyze('decomponi il task'), TaskType.plan);
    });

    test('orchestrate → plan', () {
      expect(analyzer.analyze('orchestrate this goal'), TaskType.plan);
    });

    test('orchestrazione → plan', () {
      expect(
        analyzer.analyze('ho bisogno di una orchestrazione'),
        TaskType.plan,
      );
    });

    test('pianificazione → plan', () {
      expect(analyzer.analyze('voglio una pianificazione'), TaskType.plan);
    });
  });

  group('IntentAnalyzer – coding keywords', () {
    test('implementa → coding', () {
      expect(analyzer.analyze('implementa la funzione di login'), TaskType.coding);
    });

    test('implement → coding', () {
      expect(analyzer.analyze('implement a retry mechanism'), TaskType.coding);
    });

    test('refactor → coding', () {
      expect(analyzer.analyze('refactor this class'), TaskType.coding);
    });

    test('refactoring → coding', () {
      expect(analyzer.analyze('do a refactoring of the module'), TaskType.coding);
    });

    test('debug → coding', () {
      expect(analyzer.analyze('debug this error'), TaskType.coding);
    });

    test('bugfix → coding', () {
      expect(analyzer.analyze('do a bugfix for issue 42'), TaskType.coding);
    });

    test('script → coding', () {
      expect(analyzer.analyze('write a script for this'), TaskType.coding);
    });

    test('codice → coding', () {
      expect(analyzer.analyze('scrivi del codice per questo'), TaskType.coding);
    });
  });

  group('IntentAnalyzer – chat fallback', () {
    test('general question → chat', () {
      expect(analyzer.analyze('what is the weather today?'), TaskType.chat);
    });

    test('empty string → chat', () {
      expect(analyzer.analyze(''), TaskType.chat);
    });

    test('unrelated text → chat', () {
      expect(analyzer.analyze('racconta una storia'), TaskType.chat);
    });
  });

  group('IntentAnalyzer – command takes precedence over plan', () {
    test('apri + pianifica → command', () {
      // command keywords are checked first
      expect(
        analyzer.analyze('apri e poi pianifica il progetto'),
        TaskType.command,
      );
    });
  });
}

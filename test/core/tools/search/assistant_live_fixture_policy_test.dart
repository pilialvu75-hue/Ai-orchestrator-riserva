import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/tools/search/assistant_web_search_policy.dart';

void main() {
  test('live fixtures require current public evidence', () {
    for (final prompt in [
      'Quali partite ci sono stasera?',
      'Quelles sont les rencontres de football ce soir ?',
      'Which matches are on tonight?',
      '¿Qué partidos hay esta noche?',
    ]) {
      expect(AssistantWebSearchPolicy.isSportsScheduleQuery(prompt), isTrue,
          reason: prompt);
      expect(AssistantWebSearchPolicy.shouldSearch(prompt), isTrue,
          reason: prompt);
    }
  });

  test('simple calculation and explicitly offline requests do not search', () {
    expect(AssistantWebSearchPolicy.shouldSearch('Quanto fa 17 + 24?'), isFalse);
    expect(AssistantWebSearchPolicy.shouldSearch(
      'Quali partite ci sono stasera? Non usare internet'), isFalse);
  });

  test('unavailable fixture answer never invents facts', () {
    expect(AssistantWebSearchPolicy.unavailableScheduleMessage(
      'Quali partite ci sono stasera?'), contains('Non posso confermare'));
  });
}

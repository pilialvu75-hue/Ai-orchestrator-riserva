import 'package:ai_orchestrator/core/config/ai/assistant_reply_language_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('follows explicit IT/FR/EN/ES language on each turn', () {
    expect(AssistantReplyLanguagePolicy.detect('ciao sono Giuseppe'), 'Italian');
    expect(AssistantReplyLanguagePolicy.detect('come mi chiamo ?'), 'Italian');
    expect(
      AssistantReplyLanguagePolicy.detect("comment s'appelle mon pote?"),
      'French',
    );
    expect(
      AssistantReplyLanguagePolicy.detect('mon pote est Jérôme'),
      'French',
    );
    expect(
      AssistantReplyLanguagePolicy.detect('what is my name?'),
      'English',
    );
    expect(
      AssistantReplyLanguagePolicy.detect('cómo se llama mi amigo?'),
      'Spanish',
    );
  });

  test('declines ambiguous and mixed-language messages', () {
    expect(AssistantReplyLanguagePolicy.detect('ok'), isNull);
    expect(AssistantReplyLanguagePolicy.detect('Giuseppe'), isNull);
    expect(AssistantReplyLanguagePolicy.detect('come comment'), isNull);
    expect(
      AssistantReplyLanguagePolicy.withCurrentTurnHint(
        systemPrompt: 'A custom prompt.',
        userPrompt: 'ok',
      ),
      'A custom prompt.',
    );
  });

  test('language hint is per-turn and does not retain a previous language', () {
    final french = AssistantReplyLanguagePolicy.withCurrentTurnHint(
      systemPrompt: 'Assistant core.',
      userPrompt: "comment s'appelle mon pote?",
    );
    final italian = AssistantReplyLanguagePolicy.withCurrentTurnHint(
      systemPrompt: 'Assistant core.',
      userPrompt: 'come mi chiamo?',
    );
    expect(french, contains('write in French'));
    expect(italian, contains('write in Italian'));
    expect(italian, isNot(contains('write in French')));
  });
}

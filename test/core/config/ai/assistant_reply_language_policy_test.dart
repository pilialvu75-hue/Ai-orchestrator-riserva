import 'package:ai_orchestrator/core/config/ai/assistant_reply_language_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('short greetings and explicit target language produce a hint', () {
    const cases = <String, String>{
      'ciao': 'Italian', ' Ciao! ': 'Italian',
      'bonjour': 'French', 'hello': 'English', 'hola': 'Spanish',
      'parlami in italiano': 'Italian',
      'parlami in inglese': 'English',
      'reply in italian': 'Italian',
      'réponds en espagnol': 'Spanish',
      'responde en francés': 'French',
    };
    for (final entry in cases.entries) {
      expect(AssistantReplyLanguagePolicy.detect(entry.key), entry.value);
      expect(AssistantReplyLanguagePolicy.withCurrentTurnHint(
        systemPrompt: 'Assistant core.', userPrompt: entry.key),
        contains('write in ${entry.value}'));
    }
  });

  test('quoted greetings and ambiguous short turns do not select a language', () {
    for (final text in ['"ciao"', 'ciao hello', 'ok', 'italiano']) {
      expect(AssistantReplyLanguagePolicy.detect(text), isNull, reason: text);
    }
  });

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

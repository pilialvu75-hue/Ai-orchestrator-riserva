import 'package:ai_orchestrator/core/config/ai/system_prompt_config.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SystemPromptConfig conversational core', () {
    test('default prompt is platform-neutral and continuity-aware', () {
      expect(SystemPromptConfig.defaultPrompt, contains('context-aware'));
      expect(SystemPromptConfig.defaultPrompt, contains('conversation as continuous'));
      expect(SystemPromptConfig.defaultPrompt, contains('Be concise by default'));
      expect(SystemPromptConfig.defaultPrompt, contains('Never invent facts'));
      expect(SystemPromptConfig.defaultPrompt, isNot(contains('running locally on Android')));
    });

    test('default prompt stays compact enough for small local-model context', () {
      expect(SystemPromptConfig.defaultPrompt.length, lessThanOrEqualTo(1500));
      expect(
        SystemPromptConfig.defaultPrompt.length,
        lessThan(SystemPromptConfig.previousDefaultPromptV1.length),
      );
    });

    test('recognizes current and historical bundled defaults only', () {
      expect(
        SystemPromptConfig.isBundledDefault(SystemPromptConfig.defaultPrompt),
        isTrue,
      );
      expect(
        SystemPromptConfig.isBundledDefault(
          SystemPromptConfig.previousDefaultPromptV1,
        ),
        isTrue,
      );
      expect(
        SystemPromptConfig.isBundledDefault(
          SystemPromptConfig.legacyDefaultPrompt,
        ),
        isTrue,
      );
      expect(SystemPromptConfig.isBundledDefault('Custom prompt.'), isFalse);
    });

    test('assistant chat turns receive the shared default prompt', () {
      const event = SendMessageEvent(
        sessionId: 'assistant-session',
        userPrompt: 'continua',
      );

      expect(event.systemPrompt, SystemPromptConfig.defaultPrompt);
    });

    test('explicit system prompt still overrides the shared default', () {
      const event = SendMessageEvent(
        sessionId: 'special-session',
        userPrompt: 'test',
        systemPrompt: 'specialized prompt',
      );

      expect(event.systemPrompt, 'specialized prompt');
    });
  });
}

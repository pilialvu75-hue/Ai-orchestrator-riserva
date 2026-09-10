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

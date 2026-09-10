import 'package:ai_orchestrator/core/ai/entities/ai_response.dart';
import 'package:ai_orchestrator/core/config/ai/system_prompt_config.dart';
import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  CloudRuntimeProvider createProvider() {
    return CloudRuntimeProvider(
      sendQuery: (_, request) async => AiResponse(
        text: 'unused',
        model: request.modelId ?? 'unused',
        tokensUsed: 0,
        timestamp: 0,
      ),
      supportedProviders: () => const <String>['gemini'],
      isProviderAvailable: (_) => true,
      providerDisplayName: ([name]) => name ?? 'provider',
      automaticUseAllowed: (_) => true,
    );
  }

  group('Cloud task signal isolation', () {
    test('conversational system prompt does not make ordinary chat Cloud-preferred', () {
      final provider = createProvider();

      final preferCloud = provider.shouldPreferCloudFor(
        const InferenceRequest(
          sessionId: 'ordinary-chat',
          prompt: 'Ciao, come stai?',
          systemPrompt: SystemPromptConfig.defaultPrompt,
        ),
      );

      expect(preferCloud, isFalse);
    });

    test('custom system prompt cannot classify ordinary chat as coding or reasoning', () {
      final provider = createProvider();

      final preferCloud = provider.shouldPreferCloudFor(
        const InferenceRequest(
          sessionId: 'custom-system',
          prompt: 'Hello there',
          systemPrompt: 'You are a coding, debugging and reasoning expert.',
        ),
      );

      expect(preferCloud, isFalse);
    });

    test('assistant-generated technical wording cannot escalate a later casual turn', () {
      final provider = createProvider();

      final preferCloud = provider.shouldPreferCloudFor(
        const InferenceRequest(
          sessionId: 'assistant-context',
          prompt: 'Grazie.',
          context: <ChatTurn>[
            ChatTurn(
              role: ChatRole.assistant,
              content: 'I analyzed the Flutter code, bug and debugging strategy.',
            ),
          ],
        ),
      );

      expect(preferCloud, isFalse);
    });

    test('previous user coding intent keeps a short continuation Cloud-preferred', () {
      final provider = createProvider();

      final preferCloud = provider.shouldPreferCloudFor(
        const InferenceRequest(
          sessionId: 'coding-continuation',
          prompt: 'Continua.',
          context: <ChatTurn>[
            ChatTurn(
              role: ChatRole.user,
              content: 'Debug this Flutter bug in my code.',
            ),
            ChatTurn(
              role: ChatRole.assistant,
              content: 'I found the first issue.',
            ),
          ],
        ),
      );

      expect(preferCloud, isTrue);
    });

    test('explicit coding request remains Cloud-preferred', () {
      final provider = createProvider();

      final preferCloud = provider.shouldPreferCloudFor(
        const InferenceRequest(
          sessionId: 'coding',
          prompt: 'Debug this Flutter bug in my code.',
          systemPrompt: SystemPromptConfig.defaultPrompt,
        ),
      );

      expect(preferCloud, isTrue);
    });

    test('explicit reasoning request remains Cloud-preferred', () {
      final provider = createProvider();

      final preferCloud = provider.shouldPreferCloudFor(
        const InferenceRequest(
          sessionId: 'reasoning',
          prompt: 'Analyze the tradeoff between these two strategies.',
          systemPrompt: SystemPromptConfig.defaultPrompt,
        ),
      );

      expect(preferCloud, isTrue);
    });
  });
}

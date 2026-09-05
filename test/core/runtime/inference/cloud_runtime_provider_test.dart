import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_response.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CloudRuntimeProvider', () {
    test('preserves structured history and keeps current prompt separate', () async {
      AiRequest? captured;
      final provider = CloudRuntimeProvider(
        sendQuery: (providerId, request) async {
          captured = request;
          return AiResponse(
            text: 'ok',
            model: request.modelId ?? 'unknown',
            tokensUsed: 12,
            timestamp: DateTime.now().millisecondsSinceEpoch,
          );
        },
        supportedProviders: () => const <String>['openAi'],
        isProviderAvailable: (_) => true,
        providerDisplayName: ([name]) => name ?? 'OpenAI',
      );

      final responses = await provider
          .streamInference(
            request: const InferenceRequest(
              sessionId: 'session-1',
              prompt: '  Current question  ',
              systemPrompt: 'System rules',
              context: <ChatTurn>[
                ChatTurn(role: ChatRole.user, content: 'Earlier question'),
                ChatTurn(role: ChatRole.assistant, content: 'Earlier answer'),
                ChatTurn(
                  role: ChatRole.system,
                  content: 'UI-only notice',
                  excludeFromContext: true,
                ),
              ],
            ),
            cancellationToken: CancellationToken(),
          )
          .toList();

      expect(responses, hasLength(1));
      expect(responses.single.isError, isFalse);
      expect(responses.single.text, 'ok');
      expect(captured, isNotNull);
      expect(captured!.prompt, 'Current question');
      expect(captured!.systemPrompt, 'System rules');
      expect(captured!.messages, <AiMessage>[
        const AiMessage(
          role: AiMessageRole.user,
          content: 'Earlier question',
        ),
        const AiMessage(
          role: AiMessageRole.assistant,
          content: 'Earlier answer',
        ),
      ]);
      expect(captured!.modelId, 'gpt-5.6-terra');
      expect(captured!.providerId, 'openAi');
      expect(captured!.metadata['sessionId'], 'session-1');
    });

    test('provider model callback overrides catalog default', () async {
      AiRequest? captured;
      final provider = CloudRuntimeProvider(
        sendQuery: (providerId, request) async {
          captured = request;
          return AiResponse(
            text: 'custom',
            model: request.modelId ?? 'unknown',
            tokensUsed: 1,
            timestamp: DateTime.now().millisecondsSinceEpoch,
          );
        },
        supportedProviders: () => const <String>['gemini'],
        isProviderAvailable: (_) => true,
        providerDisplayName: ([name]) => name ?? 'Gemini',
        modelForProvider: (_) => 'gemini-custom-model',
      );

      await provider
          .streamInference(
            request: const InferenceRequest(
              sessionId: 's',
              prompt: 'hello',
            ),
            cancellationToken: CancellationToken(),
          )
          .toList();

      expect(captured!.modelId, 'gemini-custom-model');
    });

    test('rate-limited preferred provider falls back and exposes retry state', () async {
      final calls = <String>[];
      final provider = CloudRuntimeProvider(
        sendQuery: (providerId, request) async {
          calls.add(providerId);
          if (providerId == 'openAi') {
            throw const ServerFailure('429 rate limit');
          }
          return AiResponse(
            text: 'fallback ok',
            model: request.modelId ?? 'unknown',
            tokensUsed: 8,
            timestamp: DateTime.now().millisecondsSinceEpoch,
          );
        },
        supportedProviders: () => const <String>['openAi', 'gemini'],
        isProviderAvailable: (_) => true,
        providerDisplayName: ([name]) => name ?? 'provider',
        preferredProvider: () => 'openAi',
      );

      final responses = await provider
          .streamInference(
            request: const InferenceRequest(
              sessionId: 's',
              prompt: 'general conversation',
            ),
            cancellationToken: CancellationToken(),
          )
          .toList();

      expect(calls, <String>['openAi', 'gemini']);
      expect(responses.single.text, 'fallback ok');
      expect(responses.single.isError, isFalse);

      final openAi = provider.providerStatuses.singleWhere(
        (status) => status.providerId == 'openAi',
      );
      final gemini = provider.providerStatuses.singleWhere(
        (status) => status.providerId == 'gemini',
      );

      expect(openAi.state, CloudProviderOperationalState.rateLimited);
      expect(openAi.retryAt, isNotNull);
      expect(openAi.failedRequests, 1);
      expect(gemini.state, CloudProviderOperationalState.ready);
    });

    test('unconfigured provider reports authRequired without exposing secrets', () {
      final provider = CloudRuntimeProvider(
        sendQuery: (_, __) async => throw StateError('not called'),
        supportedProviders: () => const <String>['claude'],
        isProviderAvailable: (_) => false,
        providerDisplayName: ([name]) => name ?? 'Claude',
      );

      final status = provider.providerStatuses.single;
      expect(status.providerId, 'claude');
      expect(status.state, CloudProviderOperationalState.authRequired);
      expect(status.lastError, isNull);
    });
  });
}

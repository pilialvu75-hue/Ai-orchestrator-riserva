import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_response.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CloudRuntimeProvider', () {
    test('preserves structured history and execution identity metadata', () async {
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
              requestId: 'request-1',
              projectId: 'project-1',
              taskId: 'task-1',
              executionId: 'execution-1',
              attemptId: 'attempt-2',
              checkpointId: 'checkpoint-7',
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

      expect(responses, hasLength(2));
      final notice = responses.first;
      expect(notice.runtimeNotice, 'cloud_provider:openAi');
      expect(notice.providerId, 'openAi');
      expect(notice.text, isEmpty);
      expect(notice.isFinal, isFalse);
      expect(notice.isError, isFalse);
      expect(notice.terminalState, isNull);

      final result = responses.where((response) => response.isFinal).single;
      expect(result, same(responses.last));
      expect(result.isError, isFalse);
      expect(result.terminalState, InferenceTerminalState.success);
      expect(result.providerId, 'openAi');
      expect(result.runtimeNotice, isNull);
      expect(result.text, 'ok');
      expect(result.tokensGenerated, 12);
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
      expect(captured!.metadata, containsPair('sessionId', 'session-1'));
      expect(captured!.metadata, containsPair('requestId', 'request-1'));
      expect(captured!.metadata, containsPair('projectId', 'project-1'));
      expect(captured!.metadata, containsPair('taskId', 'task-1'));
      expect(captured!.metadata, containsPair('executionId', 'execution-1'));
      expect(captured!.metadata, containsPair('attemptId', 'attempt-2'));
      expect(captured!.metadata, containsPair('checkpointId', 'checkpoint-7'));
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
      expect(responses, hasLength(3));
      final notices = responses.take(2).toList();
      expect(
        notices.map((notice) => notice.runtimeNotice),
        <String>['cloud_provider:openAi', 'cloud_provider:gemini'],
      );
      expect(
        notices.map((notice) => notice.providerId),
        <String>['openAi', 'gemini'],
      );
      for (final notice in notices) {
        expect(notice.text, isEmpty);
        expect(notice.isFinal, isFalse);
        expect(notice.isError, isFalse);
        expect(notice.terminalState, isNull);
      }

      final result = responses.where((response) => response.isFinal).single;
      expect(result, same(responses.last));
      expect(result.text, 'fallback ok');
      expect(result.isError, isFalse);
      expect(result.terminalState, InferenceTerminalState.success);
      expect(result.providerId, 'gemini');
      expect(result.runtimeNotice, isNull);
      expect(result.tokensGenerated, 8);

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

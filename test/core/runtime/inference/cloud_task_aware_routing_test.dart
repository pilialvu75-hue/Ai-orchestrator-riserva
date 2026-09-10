import 'package:ai_orchestrator/core/ai/entities/ai_response.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_task_class.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  CloudRuntimeProvider createProvider({
    required Future<AiResponse> Function(String provider) send,
    bool Function(String provider)? available,
  }) {
    return CloudRuntimeProvider(
      sendQuery: (provider, request) => send(provider),
      supportedProviders: () => const <String>['openAi', 'gemini'],
      isProviderAvailable: available ?? (_) => true,
      providerDisplayName: ([name]) => name ?? 'provider',
      preferredProvider: () => 'openAi',
      automaticUseAllowedForTask: (provider, task) {
        if (provider == 'gemini') return true;
        return provider == 'openAi' && task != CloudTaskClass.general;
      },
    );
  }

  AiResponse ok(String provider) => AiResponse(
        text: 'ok-$provider',
        model: 'model-$provider',
        tokensUsed: 1,
        timestamp: 0,
      );

  group('task-aware free-first Cloud routing', () {
    test('healthy free provider beats preferred paid provider for coding',
        () async {
      final calls = <String>[];
      final provider = createProvider(
        send: (providerId) async {
          calls.add(providerId);
          return ok(providerId);
        },
      );

      final responses = await provider
          .streamInference(
            request: const InferenceRequest(
              sessionId: 'coding-free-first',
              prompt: 'Correggi questo codice Flutter.',
              routeDirective: InferenceRouteDirective.cloudOnly,
              allowCloudProviderFailover: true,
            ),
            cancellationToken: CancellationToken(),
          )
          .toList();

      expect(calls, <String>['gemini']);
      expect(responses.last.providerId, 'gemini');
      expect(responses.last.text, 'ok-gemini');
    });

    test('paid provider becomes eligible for coding when free is unavailable',
        () async {
      final calls = <String>[];
      final provider = createProvider(
        available: (providerId) => providerId == 'openAi',
        send: (providerId) async {
          calls.add(providerId);
          return ok(providerId);
        },
      );

      final responses = await provider
          .streamInference(
            request: const InferenceRequest(
              sessionId: 'coding-paid-fallback',
              prompt: 'Debug this Flutter code.',
              routeDirective: InferenceRouteDirective.cloudOnly,
              allowCloudProviderFailover: true,
            ),
            cancellationToken: CancellationToken(),
          )
          .toList();

      expect(calls, <String>['openAi']);
      expect(responses.last.providerId, 'openAi');
    });

    test('paid provider follows a failed free route for complex work', () async {
      final calls = <String>[];
      final provider = createProvider(
        send: (providerId) async {
          calls.add(providerId);
          if (providerId == 'gemini') {
            throw const ServerFailure('429 rate limit');
          }
          return ok(providerId);
        },
      );

      final responses = await provider
          .streamInference(
            request: const InferenceRequest(
              sessionId: 'coding-failover',
              prompt: 'Analizza e correggi questo codice Dart.',
              routeDirective: InferenceRouteDirective.cloudOnly,
              allowCloudProviderFailover: true,
            ),
            cancellationToken: CancellationToken(),
          )
          .toList();

      expect(calls, <String>['gemini', 'openAi']);
      expect(responses.last.providerId, 'openAi');
      expect(responses.last.isError, isFalse);
    });

    test('general conversation cannot spend paid credit automatically',
        () async {
      var calls = 0;
      final provider = createProvider(
        available: (providerId) => providerId == 'openAi',
        send: (_) async {
          calls += 1;
          return ok('openAi');
        },
      );

      final responses = await provider
          .streamInference(
            request: const InferenceRequest(
              sessionId: 'general-paid-blocked',
              prompt: 'Ciao, come stai?',
              routeDirective: InferenceRouteDirective.cloudOnly,
              allowCloudProviderFailover: true,
            ),
            cancellationToken: CancellationToken(),
          )
          .toList();

      expect(calls, 0);
      expect(responses.single.isError, isTrue);
      expect(
        responses.single.errorMessage,
        CloudRuntimeProvider.automaticPolicyBlockedNotice,
      );
    });

    test('legacy canInfer stays conservative while canInferFor is task-aware',
        () {
      final provider = createProvider(
        available: (providerId) => providerId == 'openAi',
        send: (providerId) async => ok(providerId),
      );

      expect(provider.canInfer, isFalse);
      expect(
        provider.canInferFor(
          const InferenceRequest(
            sessionId: 'general-availability',
            prompt: 'Ciao.',
          ),
        ),
        isFalse,
      );
      expect(
        provider.canInferFor(
          const InferenceRequest(
            sessionId: 'coding-availability',
            prompt: 'Debug this Dart code.',
          ),
        ),
        isTrue,
      );
    });

    test('explicit continuation inherits recent user technical intent', () {
      final provider = createProvider(send: (providerId) async => ok(providerId));

      expect(
        provider.shouldPreferCloudFor(
          const InferenceRequest(
            sessionId: 'continuation',
            prompt: 'Continua.',
            context: <ChatTurn>[
              ChatTurn(
                role: ChatRole.user,
                content: 'Correggi questo codice Flutter.',
              ),
              ChatTurn(
                role: ChatRole.assistant,
                content: 'Ho individuato il primo problema.',
              ),
            ],
          ),
        ),
        isTrue,
      );
    });

    test('unrelated later message does not inherit stale coding intent', () {
      final provider = createProvider(send: (providerId) async => ok(providerId));

      expect(
        provider.shouldPreferCloudFor(
          const InferenceRequest(
            sessionId: 'new-general-turn',
            prompt: 'Grazie.',
            context: <ChatTurn>[
              ChatTurn(
                role: ChatRole.user,
                content: 'Correggi questo codice Flutter.',
              ),
              ChatTurn(
                role: ChatRole.assistant,
                content: 'Correzione completata.',
              ),
            ],
          ),
        ),
        isFalse,
      );
    });

    test('manual paid provider remains an explicit user authorization',
        () async {
      final calls = <String>[];
      final provider = createProvider(
        available: (providerId) => providerId == 'openAi',
        send: (providerId) async {
          calls.add(providerId);
          return ok(providerId);
        },
      );

      final responses = await provider
          .streamInference(
            request: const InferenceRequest(
              sessionId: 'manual-paid',
              prompt: 'Ciao.',
              routeDirective: InferenceRouteDirective.cloudOnly,
              cloudProviderId: 'openAi',
              allowCloudProviderFailover: false,
            ),
            cancellationToken: CancellationToken(),
          )
          .toList();

      expect(calls, <String>['openAi']);
      expect(responses.last.providerId, 'openAi');
    });

    test('Italian coding and architecture requests are classified as complex',
        () {
      final provider = createProvider(send: (providerId) async => ok(providerId));

      expect(
        provider.shouldPreferCloudFor(
          const InferenceRequest(
            sessionId: 'it-code',
            prompt: 'Correggi questo codice Dart.',
          ),
        ),
        isTrue,
      );
      expect(
        provider.shouldPreferCloudFor(
          const InferenceRequest(
            sessionId: 'it-architecture',
            prompt: 'Analizza questa architettura e confronta le due strategie.',
          ),
        ),
        isTrue,
      );
    });
  });
}

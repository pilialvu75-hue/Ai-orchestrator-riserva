import 'package:ai_orchestrator/core/ai/entities/ai_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CloudRuntimeProvider auth guidance', () {
    test('explicit Cloud explains how to configure an unavailable provider',
        () async {
      var calls = 0;
      final provider = CloudRuntimeProvider(
        sendQuery: (_, __) async {
          calls += 1;
          return AiResponse(
            text: 'unexpected',
            model: 'unexpected',
            tokensUsed: 0,
            timestamp: 0,
          );
        },
        supportedProviders: () => const <String>['openAi'],
        isProviderAvailable: (_) => false,
        providerDisplayName: ([name]) =>
            name == 'openAi' ? 'OpenAI' : (name ?? 'OpenAI'),
        preferredProvider: () => 'openAi',
        automaticUseAllowed: (_) => false,
      );

      final responses = await provider
          .streamInference(
            request: const InferenceRequest(
              sessionId: 'explicit-cloud-auth',
              prompt: 'hello',
              routeDirective: InferenceRouteDirective.cloudOnly,
            ),
            cancellationToken: CancellationToken(),
          )
          .toList();

      expect(calls, 0);
      expect(responses, hasLength(1));
      expect(responses.single.isError, isTrue);
      expect(
        responses.single.errorMessage,
        'OpenAI not configured. Add an API key in Settings > AI mode.',
      );
      expect(
        provider.consumeRuntimeNotice(),
        'OpenAI not configured. Add an API key in Settings > AI mode.',
      );
      expect(provider.consumeRuntimeNotice(), isNull);
    });

    test('automatic Hybrid-style routing keeps the generic local fallback',
        () async {
      var calls = 0;
      final provider = CloudRuntimeProvider(
        sendQuery: (_, __) async {
          calls += 1;
          return AiResponse(
            text: 'unexpected',
            model: 'unexpected',
            tokensUsed: 0,
            timestamp: 0,
          );
        },
        supportedProviders: () => const <String>['openAi'],
        isProviderAvailable: (_) => false,
        providerDisplayName: ([name]) => 'OpenAI',
        preferredProvider: () => 'openAi',
        automaticUseAllowed: (_) => true,
      );

      final responses = await provider
          .streamInference(
            request: const InferenceRequest(
              sessionId: 'automatic-cloud-auth',
              prompt: 'hello',
            ),
            cancellationToken: CancellationToken(),
          )
          .toList();

      expect(calls, 0);
      expect(responses, hasLength(1));
      expect(
        responses.single.errorMessage,
        CloudRuntimeProvider.fullyLocalNotice,
      );
      expect(
        provider.consumeRuntimeNotice(),
        CloudRuntimeProvider.fullyLocalNotice,
      );
    });
  });
}

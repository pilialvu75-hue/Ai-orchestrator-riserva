import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_response.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AUTO ranks opted-in free access before paid fallback', () async {
    final calls = <String>[];
    final provider = CloudRuntimeProvider(
      sendQuery: (providerId, request) async {
        calls.add(providerId);
        if (providerId != 'openAi') {
          throw const ServerFailure('temporary provider failure');
        }
        return AiResponse(
          text: 'paid fallback only after free-access tiers',
          model: request.modelId ?? 'unknown',
          tokensUsed: 4,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        );
      },
      supportedProviders: () => const <String>[
        'openAi',
        'nvidiaNim',
        'mistral',
      ],
      isProviderAvailable: (_) => true,
      providerDisplayName: ([name]) => name ?? 'provider',
      automaticUseAllowedForTask: (_, __) => true,
    );

    final responses = await provider
        .streamInference(
          request: const InferenceRequest(
            sessionId: 'point-1-5-access-ranking',
            prompt: 'hello',
            allowCloudProviderFailover: true,
          ),
          cancellationToken: CancellationToken(),
        )
        .toList();

    expect(calls, <String>['nvidiaNim', 'mistral', 'openAi']);
    expect(responses.last.isError, isFalse);
    expect(responses.last.providerId, 'openAi');
  });
}

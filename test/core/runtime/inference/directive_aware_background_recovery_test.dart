import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_response.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/background/cloud_background_execution_journal.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/directive_aware_inference_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_session_manager.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('cloudOnly surfaces previous-process interruption without auto replay',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();

    final previousBoot = CloudBackgroundExecutionJournal(
      preferences: preferences,
      bootId: 'boot-before-process-death',
      clock: () => DateTime.fromMillisecondsSinceEpoch(1000),
    );
    await previousBoot.begin(
      request: const InferenceRequest(
        sessionId: 'session-recovery',
        prompt: 'old request',
        requestId: 'old-request-id',
        routeDirective: InferenceRouteDirective.cloudOnly,
        cloudProviderId: 'gemini',
      ),
      providerHint: 'gemini',
    );

    var cloudCalls = 0;
    var localCalls = 0;
    final cloudProvider = CloudRuntimeProvider(
      sendQuery: (String provider, AiRequest request) async {
        cloudCalls += 1;
        return AiResponse(
          text: 'new response',
          model: 'gemini-test',
          tokensUsed: 3,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        );
      },
      supportedProviders: () => const <String>['gemini'],
      isProviderAvailable: (_) => true,
      providerDisplayName: ([providerName]) => 'Gemini',
      automaticUseAllowed: (_) => true,
    );

    final currentBoot = CloudBackgroundExecutionJournal(
      preferences: preferences,
      bootId: 'boot-after-process-death',
      clock: () => DateTime.fromMillisecondsSinceEpoch(2000),
    );

    final service = DirectiveAwareInferenceService(
      loadSelectedModel: () async => null,
      loadRuntimeMode: () async => AiRuntimeMode.cloud,
      runtimeProvider: _RecoveryTestLocalRuntimeProvider(
        onStream: () => localCalls += 1,
      ),
      cloudRuntimeProvider: cloudProvider,
      sessionManager: RuntimeSessionManager(),
      backgroundExecutionJournal: currentBoot,
    );

    final chunks = await service
        .stream(
          const InferenceRequest(
            sessionId: 'session-recovery',
            prompt: 'new request',
            requestId: 'new-request-id',
            routeDirective: InferenceRouteDirective.cloudOnly,
            cloudProviderId: 'gemini',
            allowCloudProviderFailover: false,
          ),
        )
        .toList();

    expect(chunks.first.runtimeNotice, contains('interrupted'));
    expect(chunks.first.runtimeNotice, contains('not retried automatically'));
    expect(chunks.last.text, 'new response');
    expect(cloudCalls, 1, reason: 'Only the new request may be executed.');
    expect(localCalls, 0);
    expect(await currentBoot.snapshot(), isEmpty);
  });
}

final class _RecoveryTestLocalRuntimeProvider extends LocalRuntimeProvider {
  _RecoveryTestLocalRuntimeProvider({required this.onStream});

  final void Function() onStream;

  @override
  bool supportsModel(AiModel model) => true;

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {
    onStream();
    yield InferenceResponse.finalChunk(
      text: 'unexpected local response',
      tokensGenerated: 1,
      model: 'local-test',
    );
  }
}

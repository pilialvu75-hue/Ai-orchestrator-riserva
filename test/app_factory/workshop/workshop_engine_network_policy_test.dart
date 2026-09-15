import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_engine.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';

void main() {
  group('WorkshopEngine network policy', () {
    test('legacy execute path remains network-capable by default', () async {
      final provider = _RecordingProvider();
      final engine = WorkshopEngine(
        inferenceGateway: WorkshopInferenceGateway(provider: provider),
      );

      final result = await engine.execute(_request('online-default'));

      expect(result.success, isTrue);
      expect(result.stage, WorkshopStage.validation);
      expect(provider.lastRequest, isNotNull);
      expect(provider.lastRequest!.isOffline, isFalse);

      await engine.dispose();
    });

    test('legacy execute path preserves explicit offline requests', () async {
      final provider = _RecordingProvider();
      final engine = WorkshopEngine(
        inferenceGateway: WorkshopInferenceGateway(provider: provider),
      );

      final result = await engine.execute(
        _request('explicit-offline'),
        isOffline: true,
      );

      expect(result.success, isTrue);
      expect(result.stage, WorkshopStage.validation);
      expect(provider.lastRequest, isNotNull);
      expect(provider.lastRequest!.isOffline, isTrue);

      await engine.dispose();
    });
  });
}

WorkshopRequest _request(String id) => WorkshopRequest(
      id: id,
      title: 'Network policy test',
      instruction: 'Prepare a safe implementation proposal.',
      operation: WorkshopOperation.modify,
    );

final class _RecordingProvider implements RuntimeInferenceProvider {
  InferenceRequest? lastRequest;

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) {
    lastRequest = request;

    return Stream<InferenceResponse>.fromIterable(
      const <InferenceResponse>[
        InferenceResponse(
          text: 'implementation proposal',
          timestamp: 1,
        ),
        InferenceResponse(
          text: '',
          timestamp: 2,
          isFinal: true,
          terminalState: InferenceTerminalState.success,
        ),
      ],
    );
  }
}

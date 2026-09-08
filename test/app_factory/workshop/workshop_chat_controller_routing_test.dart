import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_chat_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';

void main() {
  test('Workshop chat does not force offline routing by default', () async {
    final provider = _CapturingProvider();
    final controller = WorkshopChatController(
      inferenceGateway: WorkshopInferenceGateway(provider: provider),
    );

    final response = await controller.send('ciao');

    expect(response?.content, 'risposta Cantiere');
    expect(provider.lastRequest, isNotNull);
    expect(provider.lastRequest!.isOffline, isFalse);

    controller.dispose();
  });

  test('Workshop chat can still explicitly force offline routing', () async {
    final provider = _CapturingProvider();
    final controller = WorkshopChatController(
      inferenceGateway: WorkshopInferenceGateway(provider: provider),
    );

    await controller.send('ciao', isOffline: true);

    expect(provider.lastRequest, isNotNull);
    expect(provider.lastRequest!.isOffline, isTrue);

    controller.dispose();
  });
}

final class _CapturingProvider implements RuntimeInferenceProvider {
  InferenceRequest? lastRequest;

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {
    lastRequest = request;

    yield InferenceResponse.finalChunk(
      text: 'risposta Cantiere',
      tokensGenerated: 2,
      model: 'fake-workshop',
    );
  }
}

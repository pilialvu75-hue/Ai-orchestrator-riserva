import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_chat_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';

void main() {
  test('Workshop accepts a complete reply reported at the token ceiling', () async {
    final provider = _BoundaryReplyProvider();
    final controller = WorkshopChatController(
      inferenceGateway: WorkshopInferenceGateway(provider: provider),
    );

    final result = await controller.send('app per camminare');

    expect(result, isNotNull);
    expect(result!.content, endsWith('generazione.'));
    expect(controller.hasError, isFalse);
    expect(controller.lastResponseReadyForApproval, isTrue);
    expect(provider.requests, hasLength(1));
    expect(provider.requests.single.maxTokens, 384);

    controller.dispose();
  });
}

final class _BoundaryReplyProvider implements RuntimeInferenceProvider {
  final List<InferenceRequest> requests = <InferenceRequest>[];

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {
    requests.add(request);
    yield InferenceResponse.finalChunk(
      text:
          'PROPOSAL: Creo una semplice app per camminare con contapassi locale, '
          'riepilogo della sessione e persistenza sul dispositivo. Nessun backend '
          'o servizio esterno viene aggiunto. Pronto per generazione.',
      tokensGenerated: 384,
      model: 'fake-workshop',
    );
  }
}

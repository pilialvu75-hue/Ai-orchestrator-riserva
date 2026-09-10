import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_chat_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

void main() {
  test('Workshop sends current user text only as prompt, not duplicated in context',
      () async {
    final provider = _CapturingProvider();
    final controller = WorkshopChatController(
      inferenceGateway: WorkshopInferenceGateway(provider: provider),
    );

    await controller.send('prima richiesta');

    expect(provider.requests, hasLength(1));
    expect(provider.requests.single.prompt, 'prima richiesta');
    expect(provider.requests.single.context, isEmpty);

    await controller.send('seconda richiesta');

    expect(provider.requests, hasLength(2));
    final second = provider.requests.last;
    expect(second.prompt, 'seconda richiesta');
    expect(
      second.context.map((turn) => (turn.role, turn.content)).toList(),
      <(ChatRole, String)>[
        (ChatRole.user, 'prima richiesta'),
        (ChatRole.assistant, 'risposta Cantiere'),
      ],
    );
    expect(
      second.context.where((turn) => turn.content == second.prompt),
      isEmpty,
    );

    controller.dispose();
  });
}

final class _CapturingProvider implements RuntimeInferenceProvider {
  final List<InferenceRequest> requests = <InferenceRequest>[];

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {
    requests.add(request);

    yield InferenceResponse.finalChunk(
      text: 'risposta Cantiere',
      tokensGenerated: 2,
      model: 'fake-workshop',
    );
  }
}

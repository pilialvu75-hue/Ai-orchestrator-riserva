import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_chat_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';

void main() {
  test('Workshop chat hides raw stalled runtime protocol error from the UI',
      () async {
    const runtimeError =
        'AI_RUNTIME_ERROR|stage=stalled|message=Local model stalled during inference.';
    final controller = WorkshopChatController(
      inferenceGateway: WorkshopInferenceGateway(
        provider: const _ErrorProvider(runtimeError),
      ),
    );

    final response = await controller.send('continua');

    expect(response, isNull);
    expect(controller.hasError, isTrue);
    expect(controller.lastError, contains('si e fermato'));
    expect(controller.lastError, isNot(contains('AI_RUNTIME_ERROR')));
    expect(controller.lastRuntimeNotice, runtimeError);
    expect(controller.messages, isEmpty);

    controller.dispose();
  });
}

final class _ErrorProvider implements RuntimeInferenceProvider {
  const _ErrorProvider(this.message);

  final String message;

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {
    yield InferenceResponse.error(
      message,
      state: InferenceTerminalState.timeout,
    );
  }
}

import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('WorkshopInferenceGateway forwards execution continuity identities', () async {
    final provider = _CapturingProvider();
    final gateway = WorkshopInferenceGateway(provider: provider);

    await gateway
        .streamWithIdentity(
          prompt: ' build the next step ',
          sessionId: 'session-1',
          requestId: 'request-1',
          projectId: 'project-1',
          taskId: 'task-1',
          executionId: 'execution-1',
          attemptId: 'attempt-2',
          checkpointId: 'checkpoint-7',
        )
        .toList();

    final request = provider.captured;
    expect(request, isNotNull);
    expect(request!.prompt, 'build the next step');
    expect(request.sessionId, 'session-1');
    expect(request.requestId, 'request-1');
    expect(request.projectId, 'project-1');
    expect(request.taskId, 'task-1');
    expect(request.executionId, 'execution-1');
    expect(request.attemptId, 'attempt-2');
    expect(request.checkpointId, 'checkpoint-7');
  });
}

final class _CapturingProvider implements RuntimeInferenceProvider {
  InferenceRequest? captured;

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) {
    captured = request;
    return const Stream<InferenceResponse>.empty();
  }
}

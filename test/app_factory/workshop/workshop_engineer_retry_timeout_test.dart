import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_router.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';

void main() {
  group('Engineer runtime retry timeout', () {
    test('extends first-token window only for bounded Engineer retry', () async {
      final provider = _RecordingProvider();
      final executor = _executor(provider);

      await executor.complete(
        role: AppAiRole.engineer,
        prompt: 'retry implementation',
        sessionId: 'workshop:implementation:request-1:retry-1',
        maxTokens: 512,
      );

      expect(provider.requests, hasLength(1));
      expect(
        provider.requests.single.firstTokenTimeoutOverride,
        const Duration(seconds: 75),
      );

      provider.requests.clear();
      await executor.complete(
        role: AppAiRole.engineer,
        prompt: 'normal implementation',
        sessionId: 'workshop:implementation:request-1',
        maxTokens: 640,
      );

      expect(provider.requests, hasLength(1));
      expect(provider.requests.single.firstTokenTimeoutOverride, isNull);
    });

    test('preserves Cantiere identity on extended retry timeout', () async {
      final provider = _RecordingProvider();
      final executor = _executor(provider);

      await executor.completeWithIdentity(
        role: AppAiRole.engineer,
        prompt: 'resume implementation retry',
        sessionId: 'persisted-session:engineer-retry-1',
        maxTokens: 512,
        requestId: 'request-1',
        projectId: 'project-1',
        taskId: 'task-2',
        executionId: 'execution-stable',
        attemptId: 'attempt-1',
        checkpointId: 'checkpoint-1',
      );

      final request = provider.requests.single;
      expect(
        request.firstTokenTimeoutOverride,
        const Duration(seconds: 75),
      );
      expect(request.requestId, 'request-1');
      expect(request.projectId, 'project-1');
      expect(request.taskId, 'task-2');
      expect(request.executionId, 'execution-stable');
      expect(request.attemptId, 'attempt-1');
      expect(request.checkpointId, 'checkpoint-1');
    });

    test('does not silently extend Reviewer retry transport', () async {
      final provider = _RecordingProvider();
      final executor = _executor(provider);

      await executor.complete(
        role: AppAiRole.reviewer,
        prompt: 'review retry',
        sessionId: 'workshop:review:request-1:retry-1',
      );

      expect(provider.requests.single.firstTokenTimeoutOverride, isNull);
    });
  });
}

WorkshopRoleInferenceExecutor _executor(_RecordingProvider provider) {
  return WorkshopRoleInferenceExecutor(
    router: WorkshopRoleInferenceRouter(
      gateways: <AppAiRole, WorkshopInferenceGateway>{
        for (final role in WorkshopRoleInferenceRouter.workshopRoles)
          role: WorkshopInferenceGateway(provider: provider),
      },
    ),
  );
}

final class _RecordingProvider implements RuntimeInferenceProvider {
  final List<InferenceRequest> requests = <InferenceRequest>[];

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) {
    requests.add(request);
    return Stream<InferenceResponse>.fromIterable(
      const <InferenceResponse>[
        InferenceResponse(text: 'ok', timestamp: 1),
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

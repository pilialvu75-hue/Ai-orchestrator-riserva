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
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

void main() {
  group('WorkshopRoleInferenceExecutor', () {
    test('routes execution to the gateway for the requested Workshop role',
        () async {
      final gateways = <AppAiRole, _RecordingGateway>{
        for (final role in WorkshopRoleInferenceRouter.workshopRoles)
          role: _RecordingGateway(role),
      };

      final executor = WorkshopRoleInferenceExecutor(
        router: WorkshopRoleInferenceRouter(
          gateways: gateways,
        ),
      );

      for (final role in WorkshopRoleInferenceRouter.workshopRoles) {
        final result = await executor.complete(
          role: role,
          prompt: 'task for ${role.id}',
          sessionId: 'workshop:${role.id}',
        );

        expect(result.text, role.id);
        expect(gateways[role]!.calls, 1);
        expect(gateways[role]!.lastPrompt, 'task for ${role.id}');
      }
    });

    test('forwards execution continuity identity without changing executionId',
        () async {
      final provider = _RecordingProvider();
      final gateways = <AppAiRole, WorkshopInferenceGateway>{
        for (final role in WorkshopRoleInferenceRouter.workshopRoles)
          role: WorkshopInferenceGateway(provider: provider),
      };
      final executor = WorkshopRoleInferenceExecutor(
        router: WorkshopRoleInferenceRouter(gateways: gateways),
      );

      final result = await executor.completeWithIdentity(
        role: AppAiRole.engineer,
        prompt: 'implement task',
        sessionId: 'session-1',
        requestId: 'request-2',
        projectId: 'project-1',
        taskId: 'task-7',
        executionId: 'execution-stable',
        attemptId: 'attempt-3',
        checkpointId: 'checkpoint-2',
      );

      expect(result.text, 'ok');
      expect(provider.lastRequest, isNotNull);
      expect(provider.lastRequest!.sessionId, 'session-1');
      expect(provider.lastRequest!.requestId, 'request-2');
      expect(provider.lastRequest!.projectId, 'project-1');
      expect(provider.lastRequest!.taskId, 'task-7');
      expect(provider.lastRequest!.executionId, 'execution-stable');
      expect(provider.lastRequest!.attemptId, 'attempt-3');
      expect(provider.lastRequest!.checkpointId, 'checkpoint-2');
    });

    test('never routes the Assistant through the Workshop executor', () async {
      final gateways = <AppAiRole, WorkshopInferenceGateway>{
        for (final role in WorkshopRoleInferenceRouter.workshopRoles)
          role: _RecordingGateway(role),
      };

      final executor = WorkshopRoleInferenceExecutor(
        router: WorkshopRoleInferenceRouter(
          gateways: gateways,
        ),
      );

      expect(
        () => executor.complete(
          role: AppAiRole.assistantOrchestrator,
          prompt: 'must not run',
        ),
        throwsStateError,
      );
    });

    test('exposes exactly the four Workshop roles', () {
      final gateways = <AppAiRole, WorkshopInferenceGateway>{
        for (final role in WorkshopRoleInferenceRouter.workshopRoles)
          role: _RecordingGateway(role),
      };

      final executor = WorkshopRoleInferenceExecutor(
        router: WorkshopRoleInferenceRouter(
          gateways: gateways,
        ),
      );

      expect(executor.roles, WorkshopRoleInferenceRouter.workshopRoles);
      expect(executor.roles, isNot(contains(AppAiRole.assistantOrchestrator)));
    });
  });
}

final class _RecordingGateway extends WorkshopInferenceGateway {
  _RecordingGateway(this.role) : super(provider: _NoopProvider());

  final AppAiRole role;
  int calls = 0;
  String? lastPrompt;

  @override
  Future<WorkshopInferenceResult> complete({
    required String prompt,
    String? systemPrompt,
    List<ChatTurn> context = const <ChatTurn>[],
    String sessionId = 'workshop',
    bool isOffline = true,
    int? maxTokens,
    double? temperature,
    double topP = 0.9,
    double repeatPenalty = 1.1,
    String? modelId,
    String? modelPath,
    CancellationToken? cancellationToken,
  }) async {
    calls += 1;
    lastPrompt = prompt;

    return WorkshopInferenceResult(text: role.id);
  }
}

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
        InferenceResponse(text: 'ok'),
        InferenceResponse(
          text: '',
          isFinal: true,
          terminalState: InferenceTerminalState.success,
        ),
      ],
    );
  }
}

final class _NoopProvider implements RuntimeInferenceProvider {
  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) {
    return const Stream.empty();
  }
}

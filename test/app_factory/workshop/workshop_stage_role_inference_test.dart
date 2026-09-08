import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_router.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

void main() {
  group('WorkshopStageRoleResolver', () {
    test('maps active stages to the intended Workshop brains', () {
      expect(
        WorkshopStageRoleResolver.roleFor(WorkshopStage.analysis),
        AppAiRole.workshopOrchestrator,
      );
      expect(
        WorkshopStageRoleResolver.roleFor(WorkshopStage.planning),
        AppAiRole.architect,
      );
      expect(
        WorkshopStageRoleResolver.roleFor(WorkshopStage.implementation),
        AppAiRole.engineer,
      );
      expect(
        WorkshopStageRoleResolver.roleFor(WorkshopStage.review),
        AppAiRole.reviewer,
      );
      expect(
        WorkshopStageRoleResolver.roleFor(WorkshopStage.validation),
        AppAiRole.reviewer,
      );
    });

    test('never resolves a terminal stage to an inference role', () {
      for (final stage in <WorkshopStage>[
        WorkshopStage.completed,
        WorkshopStage.blocked,
        WorkshopStage.cancelled,
      ]) {
        expect(
          () => WorkshopStageRoleResolver.roleFor(stage),
          throwsStateError,
        );
      }
    });
  });

  group('WorkshopStageRoleInference', () {
    test('executes orchestrator architect engineer reviewer sequentially',
        () async {
      final callOrder = <AppAiRole>[];
      final gateways = <AppAiRole, _RecordingGateway>{
        for (final role in WorkshopRoleInferenceRouter.workshopRoles)
          role: _RecordingGateway(role, callOrder),
      };

      final coordinator = WorkshopStageRoleInference(
        executor: WorkshopRoleInferenceExecutor(
          router: WorkshopRoleInferenceRouter(gateways: gateways),
        ),
      );

      final stages = <WorkshopStage>[
        WorkshopStage.analysis,
        WorkshopStage.planning,
        WorkshopStage.implementation,
        WorkshopStage.review,
      ];

      for (final stage in stages) {
        final result = await coordinator.complete(
          stage: stage,
          prompt: 'run ${stage.name}',
          sessionId: 'workshop:stage:${stage.name}',
        );
        expect(result.hasText, isTrue);
      }

      expect(
        callOrder,
        <AppAiRole>[
          AppAiRole.workshopOrchestrator,
          AppAiRole.architect,
          AppAiRole.engineer,
          AppAiRole.reviewer,
        ],
      );
      expect(callOrder, isNot(contains(AppAiRole.assistantOrchestrator)));
      expect(gateways[AppAiRole.workshopOrchestrator]!.calls, 1);
      expect(gateways[AppAiRole.architect]!.calls, 1);
      expect(gateways[AppAiRole.engineer]!.calls, 1);
      expect(gateways[AppAiRole.reviewer]!.calls, 1);
    });

    test('forwards Cantiere execution identity through stage routing', () async {
      final provider = _RecordingProvider();
      final gateways = <AppAiRole, WorkshopInferenceGateway>{
        for (final role in WorkshopRoleInferenceRouter.workshopRoles)
          role: WorkshopInferenceGateway(provider: provider),
      };

      final coordinator = WorkshopStageRoleInference(
        executor: WorkshopRoleInferenceExecutor(
          router: WorkshopRoleInferenceRouter(gateways: gateways),
        ),
      );

      final result = await coordinator.completeWithIdentity(
        stage: WorkshopStage.implementation,
        prompt: 'implement prepared task',
        sessionId: 'session-1',
        requestId: 'request-2',
        projectId: 'project-1',
        taskId: 'task-7',
        executionId: 'execution-stable',
        attemptId: 'attempt-4',
        checkpointId: 'checkpoint-3',
      );

      expect(result.text, 'ok');
      expect(provider.lastRequest, isNotNull);
      expect(provider.lastRequest!.sessionId, 'session-1');
      expect(provider.lastRequest!.requestId, 'request-2');
      expect(provider.lastRequest!.projectId, 'project-1');
      expect(provider.lastRequest!.taskId, 'task-7');
      expect(provider.lastRequest!.executionId, 'execution-stable');
      expect(provider.lastRequest!.attemptId, 'attempt-4');
      expect(provider.lastRequest!.checkpointId, 'checkpoint-3');
    });
  });
}

final class _RecordingGateway extends WorkshopInferenceGateway {
  _RecordingGateway(this.role, this.callOrder)
      : super(provider: _NoopProvider());

  final AppAiRole role;
  final List<AppAiRole> callOrder;
  int calls = 0;

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
    callOrder.add(role);
    return WorkshopInferenceResult(text: '${role.id}:$prompt');
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

final class _NoopProvider implements RuntimeInferenceProvider {
  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) {
    return const Stream.empty();
  }
}

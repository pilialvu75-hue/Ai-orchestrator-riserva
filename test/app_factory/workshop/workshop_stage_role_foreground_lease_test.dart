import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_foreground_execution_lease.dart';
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
  test('stage inference holds and releases a foreground lease', () async {
    final leases = _RecordingLeaseService();
    final inference = WorkshopStageRoleInference(
      executor: WorkshopRoleInferenceExecutor(
        router: WorkshopRoleInferenceRouter(
          gateways: _gateways(),
        ),
      ),
      foregroundLeaseService: leases,
    );

    final result = await inference.complete(
      stage: WorkshopStage.analysis,
      prompt: 'Analyse the prepared task.',
      sessionId: 'workshop:foreground-test',
    );

    expect(result.isSuccessful, isTrue);
    expect(
      leases.operationIds,
      <String>['workshop:foreground-test:analysis'],
    );
    expect(leases.released, 1);
  });

  test('identity-aware stage inference uses the same lease boundary', () async {
    final leases = _RecordingLeaseService();
    final inference = WorkshopStageRoleInference(
      executor: WorkshopRoleInferenceExecutor(
        router: WorkshopRoleInferenceRouter(
          gateways: _gateways(),
        ),
      ),
      foregroundLeaseService: leases,
    );

    final result = await inference.completeWithIdentity(
      stage: WorkshopStage.implementation,
      prompt: 'Implement the prepared task.',
      sessionId: 'workshop:foreground-resume',
      requestId: 'request-1',
      projectId: 'project-1',
      taskId: 'task-1',
      executionId: 'execution-1',
      attemptId: 'attempt-1',
      checkpointId: 'checkpoint-1',
    );

    expect(result.isSuccessful, isTrue);
    expect(
      leases.operationIds,
      <String>['workshop:foreground-resume:implementation'],
    );
    expect(leases.released, 1);
  });
}

Map<AppAiRole, WorkshopInferenceGateway> _gateways() {
  return <AppAiRole, WorkshopInferenceGateway>{
    AppAiRole.workshopOrchestrator: _StaticGateway(),
    AppAiRole.architect: _StaticGateway(),
    AppAiRole.engineer: _StaticGateway(),
    AppAiRole.reviewer: _StaticGateway(),
  };
}

final class _RecordingLeaseService implements WorkshopExecutionLeaseService {
  final List<String> operationIds = <String>[];
  int released = 0;

  @override
  Future<WorkshopExecutionLease> acquire({
    required String operationId,
  }) async {
    operationIds.add(operationId);
    return _RecordingLease(() => released += 1);
  }
}

final class _RecordingLease implements WorkshopExecutionLease {
  _RecordingLease(this._onRelease);

  final void Function() _onRelease;
  bool _released = false;

  @override
  Future<void> release() async {
    if (_released) return;
    _released = true;
    _onRelease();
  }
}

final class _StaticGateway extends WorkshopInferenceGateway {
  _StaticGateway() : super(provider: _NoopProvider());

  @override
  Future<WorkshopInferenceResult> complete({
    required String prompt,
    String? systemPrompt,
    List<ChatTurn> context = const <ChatTurn>[],
    String sessionId = 'workshop',
    bool isOffline = false,
    int? maxTokens,
    double? temperature,
    double topP = 0.9,
    double repeatPenalty = 1.1,
    String? modelId,
    String? modelPath,
    CancellationToken? cancellationToken,
  }) async {
    return const WorkshopInferenceResult(
      text: 'ok',
      terminalState: InferenceTerminalState.success,
    );
  }
}

final class _NoopProvider implements RuntimeInferenceProvider {
  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) {
    return const Stream<InferenceResponse>.empty();
  }
}

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_preflight_inference_pipeline.dart';
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
  group('WorkshopPreflightInferencePipeline', () {
    test('routes Orchestrator then Architect and passes analysis forward', () async {
      final callOrder = <AppAiRole>[];
      final orchestrator = _RecordingGateway(
        role: AppAiRole.workshopOrchestrator,
        callOrder: callOrder,
        result: _success('scope analysis'),
      );
      final architect = _RecordingGateway(
        role: AppAiRole.architect,
        callOrder: callOrder,
        result: _success('implementation plan'),
      );
      final engineer = _RecordingGateway(
        role: AppAiRole.engineer,
        callOrder: callOrder,
        result: _success('unused'),
      );
      final reviewer = _RecordingGateway(
        role: AppAiRole.reviewer,
        callOrder: callOrder,
        result: _success('unused'),
      );

      final result = await WorkshopPreflightInferencePipeline(
        inference: _stageInference(<AppAiRole, WorkshopInferenceGateway>{
          AppAiRole.workshopOrchestrator: orchestrator,
          AppAiRole.architect: architect,
          AppAiRole.engineer: engineer,
          AppAiRole.reviewer: reviewer,
        }),
      ).run(request: _request);

      expect(result.readyForImplementation, isTrue);
      expect(
        callOrder,
        <AppAiRole>[
          AppAiRole.workshopOrchestrator,
          AppAiRole.architect,
        ],
      );
      expect(orchestrator.calls, 1);
      expect(architect.calls, 1);
      expect(engineer.calls, 0);
      expect(reviewer.calls, 0);
      expect(architect.lastPrompt, contains('scope analysis'));
      expect(architect.lastPrompt, contains(_request.instruction));
      expect(orchestrator.lastSessionId, 'workshop:preflight-request:preflight:analysis');
      expect(architect.lastSessionId, 'workshop:preflight-request:preflight:planning');
    });

    test('propagates online mode to Orchestrator and Architect', () async {
      final callOrder = <AppAiRole>[];
      final orchestrator = _RecordingGateway(
        role: AppAiRole.workshopOrchestrator,
        callOrder: callOrder,
        result: _success('scope analysis'),
      );
      final architect = _RecordingGateway(
        role: AppAiRole.architect,
        callOrder: callOrder,
        result: _success('implementation plan'),
      );

      final result = await WorkshopPreflightInferencePipeline(
        inference: _stageInference(<AppAiRole, WorkshopInferenceGateway>{
          AppAiRole.workshopOrchestrator: orchestrator,
          AppAiRole.architect: architect,
          AppAiRole.engineer: _unused(AppAiRole.engineer, callOrder),
          AppAiRole.reviewer: _unused(AppAiRole.reviewer, callOrder),
        }),
      ).run(
        request: _request,
        isOffline: false,
      );

      expect(result.readyForImplementation, isTrue);
      expect(orchestrator.lastIsOffline, isFalse);
      expect(architect.lastIsOffline, isFalse);
    });

    test('stops before Architect when Orchestrator inference fails', () async {
      final callOrder = <AppAiRole>[];
      final orchestrator = _RecordingGateway(
        role: AppAiRole.workshopOrchestrator,
        callOrder: callOrder,
        result: const WorkshopInferenceResult(
          text: '',
          terminalState: InferenceTerminalState.failed,
          errorMessage: 'runtime failure',
        ),
      );
      final architect = _RecordingGateway(
        role: AppAiRole.architect,
        callOrder: callOrder,
        result: _success('must not run'),
      );

      final result = await WorkshopPreflightInferencePipeline(
        inference: _stageInference(<AppAiRole, WorkshopInferenceGateway>{
          AppAiRole.workshopOrchestrator: orchestrator,
          AppAiRole.architect: architect,
          AppAiRole.engineer: _unused(AppAiRole.engineer, callOrder),
          AppAiRole.reviewer: _unused(AppAiRole.reviewer, callOrder),
        }),
      ).run(request: _request);

      expect(result.analysisReady, isFalse);
      expect(result.architecture, isNull);
      expect(result.readyForImplementation, isFalse);
      expect(callOrder, <AppAiRole>[AppAiRole.workshopOrchestrator]);
      expect(architect.calls, 0);
    });
  });
}

const WorkshopRequest _request = WorkshopRequest(
  id: 'preflight-request',
  title: 'Add safe feature',
  instruction: 'Implement the requested Cantiere feature safely.',
  operation: WorkshopOperation.modify,
  projectPath: '/workspace',
  targetFiles: <String>['lib/app.dart'],
  constraints: <String>['Preserve build', 'No Assistant fallback'],
  context: <String>['Existing production lifecycle is authoritative'],
);

WorkshopInferenceResult _success(String text) => WorkshopInferenceResult(
      text: text,
      terminalState: InferenceTerminalState.success,
    );

WorkshopStageRoleInference _stageInference(
  Map<AppAiRole, WorkshopInferenceGateway> gateways,
) {
  return WorkshopStageRoleInference(
    executor: WorkshopRoleInferenceExecutor(
      router: WorkshopRoleInferenceRouter(gateways: gateways),
    ),
  );
}

_RecordingGateway _unused(AppAiRole role, List<AppAiRole> callOrder) =>
    _RecordingGateway(
      role: role,
      callOrder: callOrder,
      result: _success('unused'),
    );

final class _RecordingGateway extends WorkshopInferenceGateway {
  _RecordingGateway({
    required this.role,
    required this.callOrder,
    required this.result,
  }) : super(provider: _NoopProvider());

  final AppAiRole role;
  final List<AppAiRole> callOrder;
  final WorkshopInferenceResult result;
  int calls = 0;
  String? lastPrompt;
  String? lastSessionId;
  bool? lastIsOffline;

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
    lastPrompt = prompt;
    lastSessionId = sessionId;
    lastIsOffline = isOffline;
    return result;
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

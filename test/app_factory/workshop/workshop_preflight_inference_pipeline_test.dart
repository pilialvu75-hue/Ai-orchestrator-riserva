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

    test('infers Android app target and supplies the real build contract',
        () async {
      final callOrder = <AppAiRole>[];
      final orchestrator = _RecordingGateway(
        role: AppAiRole.workshopOrchestrator,
        callOrder: callOrder,
        result: _success('Use the supported Android path.'),
      );
      final architect = _RecordingGateway(
        role: AppAiRole.architect,
        callOrder: callOrder,
        result: _success('Implement the Flutter app source.'),
      );
      const appRequest = WorkshopRequest(
        id: 'counter-app',
        title: 'Contatore',
        instruction:
            'Crea una semplice app contatore con pulsante +, pulsante - e Reset.',
        operation: WorkshopOperation.create,
      );

      final result = await WorkshopPreflightInferencePipeline(
        inference: _stageInference(<AppAiRole, WorkshopInferenceGateway>{
          AppAiRole.workshopOrchestrator: orchestrator,
          AppAiRole.architect: architect,
          AppAiRole.engineer: _unused(AppAiRole.engineer, callOrder),
          AppAiRole.reviewer: _unused(AppAiRole.reviewer, callOrder),
        }),
      ).run(request: appRequest);

      expect(result.readyForImplementation, isTrue);
      expect(orchestrator.lastPrompt, contains('TARGET BUILD CONTRACT'));
      expect(orchestrator.lastPrompt, contains('target: android'));
      expect(orchestrator.lastPrompt, contains('Flutter/Dart'));
      expect(architect.lastPrompt, contains('target: android'));
      expect(architect.lastPrompt, contains('lib/main.dart'));
    });

    test('does not force Android when the request explicitly targets Windows',
        () async {
      final callOrder = <AppAiRole>[];
      final orchestrator = _RecordingGateway(
        role: AppAiRole.workshopOrchestrator,
        callOrder: callOrder,
        result: _success('Windows scope'),
      );
      final architect = _RecordingGateway(
        role: AppAiRole.architect,
        callOrder: callOrder,
        result: _success('Windows plan'),
      );
      const windowsRequest = WorkshopRequest(
        id: 'windows-app',
        title: 'Utility Windows',
        instruction: 'Crea una piccola app Windows con file EXE finale.',
        operation: WorkshopOperation.create,
      );

      final result = await WorkshopPreflightInferencePipeline(
        inference: _stageInference(<AppAiRole, WorkshopInferenceGateway>{
          AppAiRole.workshopOrchestrator: orchestrator,
          AppAiRole.architect: architect,
          AppAiRole.engineer: _unused(AppAiRole.engineer, callOrder),
          AppAiRole.reviewer: _unused(AppAiRole.reviewer, callOrder),
        }),
      ).run(request: windowsRequest);

      expect(result.readyForImplementation, isTrue);
      expect(orchestrator.lastPrompt, contains('target: windows'));
      expect(orchestrator.lastPrompt, isNot(contains('Current Android artifact executor')));
    });

    test('keeps network-capable mode by default for Orchestrator and Architect',
        () async {
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
      ).run(request: _request);

      expect(result.readyForImplementation, isTrue);
      expect(orchestrator.lastIsOffline, isFalse);
      expect(architect.lastIsOffline, isFalse);
    });

    test('propagates explicit offline mode to Orchestrator and Architect',
        () async {
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
        isOffline: true,
      );

      expect(result.readyForImplementation, isTrue);
      expect(orchestrator.lastIsOffline, isTrue);
      expect(architect.lastIsOffline, isTrue);
    });

    test(
        'reuses owner-approved proposal and skips duplicate Orchestrator inference',
        () async {
      final callOrder = <AppAiRole>[];
      final orchestrator = _RecordingGateway(
        role: AppAiRole.workshopOrchestrator,
        callOrder: callOrder,
        result: _success('must not run'),
      );
      final architect = _RecordingGateway(
        role: AppAiRole.architect,
        callOrder: callOrder,
        result: _success('implementation plan'),
      );
      final request = WorkshopRequest(
        id: 'approved-counter-app',
        title: 'Contatore',
        instruction:
            'Crea una semplice app contatore con pulsante +, pulsante - e Reset.',
        operation: WorkshopOperation.create,
        context: <String>[
          WorkshopPreflightInferencePipeline.approvedProposalContextEntry(
            'Proposta: app contatore con +, - e Reset.',
          ),
        ],
      );

      final result = await WorkshopPreflightInferencePipeline(
        inference: _stageInference(<AppAiRole, WorkshopInferenceGateway>{
          AppAiRole.workshopOrchestrator: orchestrator,
          AppAiRole.architect: architect,
          AppAiRole.engineer: _unused(AppAiRole.engineer, callOrder),
          AppAiRole.reviewer: _unused(AppAiRole.reviewer, callOrder),
        }),
      ).run(request: request);

      expect(result.readyForImplementation, isTrue);
      expect(orchestrator.calls, 0);
      expect(architect.calls, 1);
      expect(callOrder, <AppAiRole>[AppAiRole.architect]);
      expect(
        result.analysis.text,
        contains('OWNER-APPROVED PROJECT VISION AVAILABLE AS BACKGROUND'),
      );
      expect(result.analysis.text, contains(request.instruction));
      expect(
        result.analysis.text,
        isNot(contains('Proposta: app contatore con +, - e Reset.')),
      );
      expect(architect.lastPrompt, contains('target: android'));
      expect(architect.lastPrompt, contains('CURRENT TASK SCOPE RULE'));
      expect(
        architect.lastPrompt,
        contains('OWNER-APPROVED PROJECT VISION (BACKGROUND)'),
      );
      expect(
        architect.lastPrompt,
        contains('Proposta: app contatore con +, - e Reset.'),
      );
      expect(
        architect.lastPrompt,
        contains('not a requirement to implement every feature now'),
      );
    });

    test('keeps a broad approved proposal as background for one-task MVP planning',
        () async {
      final callOrder = <AppAiRole>[];
      final architect = _RecordingGateway(
        role: AppAiRole.architect,
        callOrder: callOrder,
        result: _success('minimal walking MVP plan'),
      );
      final request = WorkshopRequest(
        id: 'walking-mvp',
        title: 'App per camminare',
        instruction: 'fai un app per camminare',
        operation: WorkshopOperation.create,
        context: <String>[
          WorkshopPreflightInferencePipeline.approvedProposalContextEntry(
            'Tracking camminata, obiettivi settimanali, motivazione, '
            'feedback dettagliato e futura evoluzione multipiattaforma.',
          ),
        ],
      );

      final result = await WorkshopPreflightInferencePipeline(
        inference: _stageInference(<AppAiRole, WorkshopInferenceGateway>{
          AppAiRole.workshopOrchestrator:
              _unused(AppAiRole.workshopOrchestrator, callOrder),
          AppAiRole.architect: architect,
          AppAiRole.engineer: _unused(AppAiRole.engineer, callOrder),
          AppAiRole.reviewer: _unused(AppAiRole.reviewer, callOrder),
        }),
      ).run(request: request);

      expect(result.readyForImplementation, isTrue);
      expect(callOrder, <AppAiRole>[AppAiRole.architect]);
      expect(architect.lastPrompt, contains('fai un app per camminare'));
      expect(architect.lastPrompt, contains('CURRENT TASK SCOPE RULE'));
      expect(
        architect.lastPrompt,
        contains('Plan the smallest runnable increment'),
      );
      expect(
        architect.lastPrompt,
        contains('OWNER-APPROVED PROJECT VISION (BACKGROUND)'),
      );
      expect(architect.lastPrompt, contains('obiettivi settimanali'));
      expect(
        architect.lastPrompt,
        contains('not a requirement to implement every feature now'),
      );
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
    bool isOffline = false,
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

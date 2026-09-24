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
  group('Workshop preflight resume', () {
    test('retries transient Architect failure inside the same preflight',
        () async {
      final orchestrator = _SequenceGateway(
        role: AppAiRole.workshopOrchestrator,
        results: <WorkshopInferenceResult>[
          _success('scope analysis'),
        ],
      );
      final architect = _SequenceGateway(
        role: AppAiRole.architect,
        results: <WorkshopInferenceResult>[
          const WorkshopInferenceResult(
            text: '',
            terminalState: InferenceTerminalState.failed,
            errorMessage: 'architect stalled',
          ),
          _success('implementation plan'),
        ],
      );
      final pipeline = _pipeline(
        orchestrator: orchestrator,
        architect: architect,
      );

      final result = await pipeline.run(request: _request);

      expect(result.analysisReady, isTrue);
      expect(result.architectureReady, isTrue);
      expect(result.readyForImplementation, isTrue);
      expect(result.analysis.text, 'scope analysis');
      expect(result.architecture?.text, 'implementation plan');
      expect(orchestrator.calls, 1);
      expect(architect.calls, 2);
      expect(
        architect.sessionIds,
        <String>[
          'workshop:resume-preflight-request:preflight:planning',
          'workshop:resume-preflight-request:preflight:planning:retry-1',
        ],
      );
    });

    test('approved project vision stays out of Architect current-task prompt',
        () async {
      const marker = 'UNIQUE_APPROVED_PROPOSAL_MARKER';
      final orchestrator = _SequenceGateway(
        role: AppAiRole.workshopOrchestrator,
        results: <WorkshopInferenceResult>[
          _success('unused analysis'),
        ],
      );
      final architect = _SequenceGateway(
        role: AppAiRole.architect,
        results: <WorkshopInferenceResult>[
          _success('implementation plan'),
        ],
      );
      final pipeline = _pipeline(
        orchestrator: orchestrator,
        architect: architect,
      );
      final request = WorkshopRequest(
        id: 'approved-proposal-dedup',
        title: 'Build approved app',
        instruction: 'Build the app from the approved proposal.',
        operation: WorkshopOperation.create,
        projectPath: '/workspace',
        constraints: const <String>['Keep scope bounded'],
        context: <String>[
          WorkshopPreflightInferencePipeline.approvedProposalContextEntry(
            'Complete proposal $marker',
          ),
          'Independent context',
        ],
      );

      final result = await pipeline.run(request: request);

      expect(result.readyForImplementation, isTrue);
      expect(orchestrator.calls, 0);
      expect(architect.calls, 1);
      final prompt = architect.prompts.single;
      expect(RegExp(marker).allMatches(prompt), isEmpty);
      expect(result.analysis.text, isNot(contains(marker)));
      expect(prompt, contains('Independent context'));
      expect(prompt, contains('CURRENT TASK SCOPE RULE'));
      expect(
        prompt,
        isNot(contains(
          WorkshopPreflightInferencePipeline.approvedProposalContextPrefix,
        )),
      );
    });

    test('certified Library identity invalidates stale preflight resume',
        () async {
      final orchestrator = _SequenceGateway(
        role: AppAiRole.workshopOrchestrator,
        results: <WorkshopInferenceResult>[
          _success('analysis for certified export A'),
          _success('analysis for certified export B'),
        ],
      );
      final architect = _SequenceGateway(
        role: AppAiRole.architect,
        results: <WorkshopInferenceResult>[
          _success('plan for certified export A'),
          _success('plan for certified export B'),
        ],
      );
      final pipeline = _pipeline(
        orchestrator: orchestrator,
        architect: architect,
      );

      final first = await pipeline.run(
        request: _request,
        allowLocalReuse: false,
        certifiedLibraryReuseIdentity: 'snapshot-a|asset@1:package-a',
      );
      expect(first.readyForImplementation, isTrue);
      expect(orchestrator.calls, 1);
      expect(architect.calls, 1);

      final sameExport = await pipeline.run(
        request: _request,
        allowLocalReuse: false,
        certifiedLibraryReuseIdentity: 'snapshot-a|asset@1:package-a',
      );
      expect(sameExport.analysis.text, 'analysis for certified export A');
      expect(orchestrator.calls, 1);
      expect(architect.calls, 1);

      final changedExport = await pipeline.run(
        request: _request,
        allowLocalReuse: false,
        certifiedLibraryReuseIdentity: 'snapshot-b|asset@2:package-b',
      );
      expect(changedExport.analysis.text, 'analysis for certified export B');
      expect(changedExport.architecture?.text, 'plan for certified export B');
      expect(orchestrator.calls, 2);
      expect(architect.calls, 2);
    });

    test('does not reuse online analysis for an explicit offline retry',
        () async {
      final orchestrator = _SequenceGateway(
        role: AppAiRole.workshopOrchestrator,
        results: <WorkshopInferenceResult>[
          _success('online analysis'),
          _success('offline analysis'),
        ],
      );
      final architect = _SequenceGateway(
        role: AppAiRole.architect,
        results: const <WorkshopInferenceResult>[
          WorkshopInferenceResult(
            text: '',
            terminalState: InferenceTerminalState.failed,
            errorMessage: 'online architect stalled',
          ),
          WorkshopInferenceResult(
            text: '',
            terminalState: InferenceTerminalState.failed,
            errorMessage: 'online architect retry stalled',
          ),
          WorkshopInferenceResult(
            text: '',
            terminalState: InferenceTerminalState.failed,
            errorMessage: 'offline architect stalled',
          ),
          WorkshopInferenceResult(
            text: '',
            terminalState: InferenceTerminalState.failed,
            errorMessage: 'offline architect retry stalled',
          ),
        ],
      );
      final pipeline = _pipeline(
        orchestrator: orchestrator,
        architect: architect,
      );

      final online = await pipeline.run(request: _request);
      expect(online.analysis.text, 'online analysis');

      final offline = await pipeline.run(
        request: _request,
        isOffline: true,
      );
      expect(offline.analysis.text, 'offline analysis');
      expect(orchestrator.calls, 2);
      expect(orchestrator.offlineValues, <bool>[false, true]);
      expect(
        architect.offlineValues,
        <bool>[false, false, true, true],
      );
    });
  });
}

const WorkshopRequest _request = WorkshopRequest(
  id: 'resume-preflight-request',
  title: 'Resume preflight safely',
  instruction: 'Implement the Cantiere task without repeating completed stages.',
  operation: WorkshopOperation.modify,
  projectPath: '/workspace',
  targetFiles: <String>['lib/app.dart'],
  constraints: <String>['No Assistant fallback'],
  context: <String>['Prepared task is authoritative'],
);

WorkshopPreflightInferencePipeline _pipeline({
  required _SequenceGateway orchestrator,
  required _SequenceGateway architect,
}) {
  final unusedEngineer = _SequenceGateway(
    role: AppAiRole.engineer,
    results: <WorkshopInferenceResult>[_success('unused')],
  );
  final unusedReviewer = _SequenceGateway(
    role: AppAiRole.reviewer,
    results: <WorkshopInferenceResult>[_success('unused')],
  );

  return WorkshopPreflightInferencePipeline(
    inference: WorkshopStageRoleInference(
      executor: WorkshopRoleInferenceExecutor(
        router: WorkshopRoleInferenceRouter(
          gateways: <AppAiRole, WorkshopInferenceGateway>{
            AppAiRole.workshopOrchestrator: orchestrator,
            AppAiRole.architect: architect,
            AppAiRole.engineer: unusedEngineer,
            AppAiRole.reviewer: unusedReviewer,
          },
        ),
      ),
    ),
  );
}

WorkshopInferenceResult _success(String text) => WorkshopInferenceResult(
      text: text,
      terminalState: InferenceTerminalState.success,
    );

final class _SequenceGateway extends WorkshopInferenceGateway {
  _SequenceGateway({
    required this.role,
    required List<WorkshopInferenceResult> results,
  })  : _results = List<WorkshopInferenceResult>.of(results),
        super(provider: _NoopProvider());

  final AppAiRole role;
  final List<WorkshopInferenceResult> _results;
  final List<bool> offlineValues = <bool>[];
  final List<String> prompts = <String>[];
  final List<String> sessionIds = <String>[];
  int calls = 0;

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
    offlineValues.add(isOffline);
    prompts.add(prompt);
    sessionIds.add(sessionId);
    final index = calls;
    calls += 1;
    if (index >= _results.length) {
      throw StateError('Unexpected extra ${role.name} preflight call.');
    }
    return _results[index];
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

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_preflight_inference_pipeline.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_implementation_runner.dart';
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
  group('WorkshopProposalImplementationRunner', () {
    test('routes only to Engineer and stages proposal for review without writes',
        () async {
      final engineer = _StaticGateway(
        result: const WorkshopInferenceResult(
          text: '''
{"summary":"Update app","explanation":"Apply requested change","changes":[{"path":"lib/app.dart","type":"modification","content":"new"}],"validationNotes":[],"warnings":[]}
''',
          terminalState: InferenceTerminalState.success,
          model: 'engineer-model',
        ),
      );
      final gateways = _gateways(engineer);
      final workspaceGateway = _RecordingWorkspaceGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final session = await _session(workspaceGateway);
      final longPlan = <String>[
        'bounded implementation plan from Architect: implement walking tracking.',
        List<String>.filled(1200, 'middle').join(' '),
        'ACCEPTANCE: show visible user feedback for walking progress.',
      ].join('\n');
      final preflight = WorkshopPreflightInferenceResult(
        analysis: const WorkshopInferenceResult(
          text: 'scope analysis from Orchestrator',
          terminalState: InferenceTerminalState.success,
        ),
        architecture: WorkshopInferenceResult(
          text: longPlan,
          terminalState: InferenceTerminalState.success,
        ),
      );

      final proposal = await WorkshopProposalImplementationRunner(
        inference: _stageInference(gateways),
      ).run(
        session: session,
        preflight: preflight,
      );

      expect(proposal.changes, hasLength(1));
      expect(session.workspace.read('lib/app.dart'), 'new');
      expect(session.status, WorkspaceSessionStatus.review);
      expect(session.isApplyApproved, isFalse);
      expect(engineer.calls, 1);
      expect(engineer.lastPrompt, contains('"lib/app.dart":"old"'));
      expect(
        engineer.lastPrompt,
        isNot(contains('scope analysis from Orchestrator')),
      );
      expect(
        engineer.lastPrompt,
        contains('bounded implementation plan from Architect'),
      );
      expect(
        engineer.lastPrompt,
        contains('ACCEPTANCE: show visible user feedback for walking progress.'),
      );
      expect(engineer.lastPrompt, contains('[bounded middle omitted]'));
      expect(
        engineer.lastPrompt,
        contains('explicit task instruction and constraints are authoritative'),
      );
      expect(engineer.lastPrompt, contains('Architect'));
      expect(engineer.lastPrompt, contains('UI LITERAL FIDELITY'));
      expect(engineer.lastPrompt, contains('"+" into "+1"'));
      expect(
        engineer.lastPrompt,
        contains('plan is model-authored implementation guidance'),
      );
      expect(engineer.maxTokensValues, <int?>[640]);
      expect(engineer.lastPrompt!.length, lessThan(6000));
      expect(gateways[AppAiRole.workshopOrchestrator]!.calls, 0);
      expect(gateways[AppAiRole.architect]!.calls, 0);
      expect(gateways[AppAiRole.reviewer]!.calls, 0);
      expect(workspaceGateway.writeCalls, 0);
      expect(workspaceGateway.deleteCalls, 0);
      expect(workspaceGateway.commitCalls, 0);
      expect(workspaceGateway.pushCalls, 0);
      expect(workspaceGateway.pullRequestCalls, 0);
    });

    test(
        'create task may replace an oversized explicit scaffold without reading it',
        () async {
      final engineer = _StaticGateway(
        result: const WorkshopInferenceResult(
          text:
              '{"summary":"Replace scaffold","explanation":"Create bounded entry point","changes":[{"path":"lib/main.dart","type":"modification","content":"void main() {}"}],"validationNotes":[],"warnings":[]}',
          terminalState: InferenceTerminalState.success,
          model: 'engineer-model',
        ),
      );
      final oversizedScaffold = List<String>.filled(2600, 'x').join();
      final workspaceGateway = _RecordingWorkspaceGateway(
        files: <String, String>{'lib/main.dart': oversizedScaffold},
      );
      final session = WorkspaceSession(
        request: const WorkshopRequest(
          id: 'create-oversized-scaffold',
          title: 'Create app foundation',
          instruction: 'Replace the starter entry point with a minimal app.',
          operation: WorkshopOperation.create,
          targetFiles: <String>['lib/main.dart'],
        ),
        gateway: workspaceGateway,
      );
      await session.initialize();

      final proposal = await WorkshopProposalImplementationRunner(
        inference: _stageInference(_gateways(engineer)),
      ).run(session: session);

      expect(proposal.changes.single.path, 'lib/main.dart');
      expect(session.workspace.read('lib/main.dart'), 'void main() {}');
      expect(
        engineer.lastPrompt,
        contains('"replaceableTargets":["lib/main.dart"]'),
      );
      expect(
        engineer.lastPrompt,
        isNot(contains(List<String>.filled(256, 'x').join())),
      );
      expect(engineer.calls, 1);
      expect(workspaceGateway.writeCalls, 0);
    });

    test('modify task still fails closed for an oversized explicit target',
        () async {
      final engineer = _StaticGateway(
        result: const WorkshopInferenceResult(
          text: '{}',
          terminalState: InferenceTerminalState.success,
        ),
      );
      final workspaceGateway = _RecordingWorkspaceGateway(
        files: <String, String>{
          'lib/main.dart': List<String>.filled(2600, 'x').join(),
        },
      );
      final session = WorkspaceSession(
        request: const WorkshopRequest(
          id: 'modify-oversized-target',
          title: 'Modify existing app',
          instruction: 'Make a bounded change without losing existing code.',
          operation: WorkshopOperation.modify,
          targetFiles: <String>['lib/main.dart'],
        ),
        gateway: workspaceGateway,
      );
      await session.initialize();

      await expectLater(
        WorkshopProposalImplementationRunner(
          inference: _stageInference(_gateways(engineer)),
        ).run(session: session),
        throwsA(
          isA<StateError>().having(
            (error) => error.toString(),
            'message',
            contains('exceeds the local prompt budget'),
          ),
        ),
      );

      expect(engineer.calls, 0);
      expect(session.workspace.read('lib/main.dart'), isNot('void main() {}'));
      expect(workspaceGateway.writeCalls, 0);
    });


    test('out-of-scope create file retries inside hard target allowlist',
        () async {
      final engineer = _StaticGateway(
        results: <WorkshopInferenceResult>[
          const WorkshopInferenceResult(
            text:
                '{"explanation":"Split counter","changes":[{"path":"lib/contatore_test.dart","type":"addition","content":"class CounterApp {}"}]}',
            terminalState: InferenceTerminalState.success,
            model: 'engineer-model',
          ),
          const WorkshopInferenceResult(
            text:
                '{"explanation":"Keep counter in entrypoint","changes":[{"path":"lib/main.dart","type":"modification","content":"void main() {}"}]}',
            terminalState: InferenceTerminalState.success,
            model: 'engineer-model',
          ),
        ],
      );
      final workspaceGateway = _RecordingWorkspaceGateway(
        files: <String, String>{'lib/main.dart': 'void main() { }'},
      );
      final session = WorkspaceSession(
        request: const WorkshopRequest(
          id: 'counter-hard-allowlist',
          title: 'Contatore Test',
          instruction:
              'Create the counter app in the requested Flutter entrypoint.',
          operation: WorkshopOperation.create,
          targetFiles: <String>['lib/main.dart'],
        ),
        gateway: workspaceGateway,
      );
      await session.initialize();

      final proposal = await WorkshopProposalImplementationRunner(
        inference: _stageInference(_gateways(engineer)),
      ).run(session: session);

      expect(proposal.changes.single.path, 'lib/main.dart');
      expect(engineer.calls, 2);
      expect(engineer.maxTokensValues, <int?>[640, 768]);
      expect(
        engineer.prompts.first,
        contains('"targetFilesPolicy":"hard_allowlist"'),
      );
      expect(engineer.prompts.first, contains('HARD ALLOWLIST'));
      expect(engineer.prompts.last, contains('lib/contatore_test.dart'));
      expect(
        engineer.prompts.last,
        contains('outside the current task targetFiles'),
      );
      expect(session.workspace.read('lib/main.dart'), 'void main() {}');
      expect(workspaceGateway.writeCalls, 0);
    });

    test('retries a local Engineer first-token stall with compact prompt',
        () async {
      final engineer = _StaticGateway(
        results: <WorkshopInferenceResult>[
          const WorkshopInferenceResult(
            text: '',
            terminalState: InferenceTerminalState.failed,
            errorMessage:
                'AI_RUNTIME_ERROR|stage=stalled|message=Local model stalled during inference.',
          ),
          const WorkshopInferenceResult(
            text: '''
{"summary":"Recovered","explanation":"Retry succeeded","changes":[{"path":"lib/app.dart","type":"modification","content":"new"}],"validationNotes":[],"warnings":[]}
''',
            terminalState: InferenceTerminalState.success,
            model: 'engineer-model',
          ),
        ],
      );
      final workspaceGateway = _RecordingWorkspaceGateway(
        files: <String, String>{
          'lib/app.dart': 'old',
          'lib/unrelated.dart': List<String>.filled(3000, 'x').join(),
        },
      );
      final session = await _session(workspaceGateway);
      final preflight = WorkshopPreflightInferenceResult(
        analysis: const WorkshopInferenceResult(
          text: 'large orchestrator analysis that Engineer should not need',
          terminalState: InferenceTerminalState.success,
        ),
        architecture: const WorkshopInferenceResult(
          text: 'Modify lib/app.dart only and validate the result.',
          terminalState: InferenceTerminalState.success,
        ),
      );

      final proposal = await WorkshopProposalImplementationRunner(
        inference: _stageInference(_gateways(engineer)),
      ).run(
        session: session,
        preflight: preflight,
      );

      expect(proposal.changes.single.path, 'lib/app.dart');
      expect(session.workspace.read('lib/app.dart'), 'new');
      expect(engineer.calls, 2);
      expect(
        engineer.sessionIds,
        <String>[
          'workshop:implementation:implementation-runner-request',
          'workshop:implementation:implementation-runner-request:retry-1',
        ],
      );
      expect(engineer.maxTokensValues, <int?>[640, 512]);
      expect(engineer.prompts[1].length, lessThan(engineer.prompts[0].length));
      expect(
        engineer.prompts.every(
          (prompt) => !prompt.contains('large orchestrator analysis'),
        ),
        isTrue,
      );
      expect(
        engineer.prompts.every(
          (prompt) => !prompt.contains(List<String>.filled(128, 'x').join()),
        ),
        isTrue,
      );
      expect(workspaceGateway.writeCalls, 0);
    });

    test('retries critical-memory Engineer with a fresh runtime token',
        () async {
      final engineer = _StaticGateway(
        results: <WorkshopInferenceResult>[
          const WorkshopInferenceResult(
            text: '',
            terminalState: InferenceTerminalState.failed,
            errorMessage:
                'AI_RUNTIME_ERROR|stage=critical_memory|message=Generazione fermata per pressione sulla memoria.',
          ),
          const WorkshopInferenceResult(
            text:
                '{"summary":"Recovered","explanation":"Memory retry succeeded","changes":[{"path":"lib/app.dart","type":"modification","content":"new"}],"validationNotes":[],"warnings":[]}',
            terminalState: InferenceTerminalState.success,
            model: 'engineer-model',
          ),
        ],
      );
      final workspaceGateway = _RecordingWorkspaceGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final session = await _session(workspaceGateway);
      final callerToken = CancellationToken();

      final proposal = await WorkshopProposalImplementationRunner(
        inference: _stageInference(_gateways(engineer)),
      ).run(
        session: session,
        cancellationToken: callerToken,
      );

      expect(proposal.explanation, 'Memory retry succeeded');
      expect(session.workspace.read('lib/app.dart'), 'new');
      expect(engineer.calls, 2);
      expect(callerToken.isCancelled, isFalse);
      expect(
        engineer.sessionIds,
        <String>[
          'workshop:implementation:implementation-runner-request',
          'workshop:implementation:implementation-runner-request:retry-1',
        ],
      );
      expect(engineer.maxTokensValues, <int?>[640, 512]);
      expect(engineer.cancellationTokenWasNull, <bool>[false, false]);
      expect(engineer.prompts[1].length, lessThan(engineer.prompts[0].length));
      expect(workspaceGateway.writeCalls, 0);
    });

    test('caller cancellation suppresses critical-memory retry', () async {
      final engineer = _StaticGateway(
        results: <WorkshopInferenceResult>[
          const WorkshopInferenceResult(
            text: '',
            terminalState: InferenceTerminalState.failed,
            errorMessage:
                'AI_RUNTIME_ERROR|stage=critical_memory|message=Generazione fermata per pressione sulla memoria.',
          ),
        ],
      );
      final workspaceGateway = _RecordingWorkspaceGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final session = await _session(workspaceGateway);
      final callerToken = CancellationToken()..cancel();

      await expectLater(
        WorkshopProposalImplementationRunner(
          inference: _stageInference(_gateways(engineer)),
        ).run(
          session: session,
          cancellationToken: callerToken,
        ),
        throwsA(isA<StateError>()),
      );

      expect(engineer.calls, 1);
      expect(callerToken.isCancelled, isTrue);
      expect(workspaceGateway.writeCalls, 0);
    });

    test('retries syntactically truncated Engineer JSON with larger compact budget',
        () async {
      final engineer = _StaticGateway(
        results: <WorkshopInferenceResult>[
          const WorkshopInferenceResult(
            text:
                '{"explanation":"partial","changes":[{"path":"lib/app.dart","type":"modification","content":"void main() {\\n  print(\"walk\");',
            terminalState: InferenceTerminalState.success,
            model: 'engineer-model',
          ),
          const WorkshopInferenceResult(
            text:
                '{"explanation":"Recovered","changes":[{"path":"lib/app.dart","type":"addition|modification","content":"void main() {\\n  print(\\\"walk\\\");\\n}"}]}',
            terminalState: InferenceTerminalState.success,
            model: 'engineer-model',
          ),
        ],
      );
      final workspaceGateway = _RecordingWorkspaceGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final session = await _session(workspaceGateway);
      final preflight = WorkshopPreflightInferenceResult(
        analysis: const WorkshopInferenceResult(
          text: 'analysis',
          terminalState: InferenceTerminalState.success,
        ),
        architecture: const WorkshopInferenceResult(
          text: 'Implement a minimal walking app safely.',
          terminalState: InferenceTerminalState.success,
        ),
      );

      final proposal = await WorkshopProposalImplementationRunner(
        inference: _stageInference(_gateways(engineer)),
      ).run(
        session: session,
        preflight: preflight,
      );

      expect(proposal.changes.single.path, 'lib/app.dart');
      expect(proposal.changes.single.isModification, isTrue);
      expect(
        session.workspace.read('lib/app.dart'),
        'void main() {\n  print("walk");\n}',
      );
      expect(engineer.calls, 2);
      expect(
        engineer.sessionIds,
        <String>[
          'workshop:implementation:implementation-runner-request',
          'workshop:implementation:implementation-runner-request:retry-malformed-1',
        ],
      );
      expect(engineer.maxTokensValues, <int?>[640, 768]);
      expect(engineer.prompts[1].length, lessThan(engineer.prompts[0].length));
      expect(workspaceGateway.writeCalls, 0);
    });

    test('recovers omitted explanation from summary without retry', () async {
      final engineer = _StaticGateway(
        result: const WorkshopInferenceResult(
          text:
              '{"summary":"Walking MVP","changes":[{"path":"lib/app.dart","type":"modification","content":"new"}],"validationNotes":[],"warnings":[]}',
          terminalState: InferenceTerminalState.success,
          model: 'engineer-model',
        ),
      );
      final workspaceGateway = _RecordingWorkspaceGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final session = await _session(workspaceGateway);
      final preflight = WorkshopPreflightInferenceResult(
        analysis: const WorkshopInferenceResult(
          text: 'analysis',
          terminalState: InferenceTerminalState.success,
        ),
        architecture: const WorkshopInferenceResult(
          text: 'Implement the smallest walking MVP safely.',
          terminalState: InferenceTerminalState.success,
        ),
      );

      final proposal = await WorkshopProposalImplementationRunner(
        inference: _stageInference(_gateways(engineer)),
      ).run(
        session: session,
        preflight: preflight,
      );

      expect(proposal.explanation, 'Walking MVP');
      expect(proposal.changes.single.path, 'lib/app.dart');
      expect(session.workspace.read('lib/app.dart'), 'new');
      expect(engineer.calls, 1);
      expect(
        engineer.sessionIds,
        <String>['workshop:implementation:implementation-runner-request'],
      );
      expect(engineer.maxTokensValues, <int?>[640]);
      expect(workspaceGateway.writeCalls, 0);
    });

    test('does not retry valid changes only because metadata is missing', () async {
      final engineer = _StaticGateway(
        result: const WorkshopInferenceResult(
          text:
              '{"changes":[{"path":"lib/app.dart","type":"modification","content":"new"}],"validationNotes":[],"warnings":[]}',
          terminalState: InferenceTerminalState.success,
          model: 'engineer-model',
        ),
      );
      final workspaceGateway = _RecordingWorkspaceGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final session = await _session(workspaceGateway);

      final proposal = await WorkshopProposalImplementationRunner(
        inference: _stageInference(_gateways(engineer)),
      ).run(session: session);

      expect(proposal.explanation, 'Proposed file change: lib/app.dart');
      expect(engineer.calls, 1);
      expect(engineer.maxTokensValues, <int?>[640]);
      expect(session.workspace.read('lib/app.dart'), 'new');
      expect(workspaceGateway.writeCalls, 0);
    });

    test('cancelled Engineer inference is not retried', () async {
      final engineer = _StaticGateway(
        result: const WorkshopInferenceResult(
          text: '',
          terminalState: InferenceTerminalState.cancelled,
          errorMessage: 'cancelled by caller',
        ),
      );
      final workspaceGateway = _RecordingWorkspaceGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final session = await _session(workspaceGateway);

      await expectLater(
        WorkshopProposalImplementationRunner(
          inference: _stageInference(_gateways(engineer)),
        ).run(session: session),
        throwsA(isA<StateError>()),
      );

      expect(engineer.calls, 1);
      expect(engineer.maxTokensValues, <int?>[640]);
      expect(session.workspace.read('lib/app.dart'), 'old');
    });

    test('rejects incomplete preflight before Engineer inference', () async {
      final engineer = _StaticGateway(
        result: const WorkshopInferenceResult(
          text: '{}',
          terminalState: InferenceTerminalState.success,
        ),
      );
      final workspaceGateway = _RecordingWorkspaceGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final session = await _session(workspaceGateway);
      final incompletePreflight = WorkshopPreflightInferenceResult(
        analysis: const WorkshopInferenceResult(
          text: 'analysis only',
          terminalState: InferenceTerminalState.success,
        ),
      );

      await expectLater(
        WorkshopProposalImplementationRunner(
          inference: _stageInference(_gateways(engineer)),
        ).run(
          session: session,
          preflight: incompletePreflight,
        ),
        throwsA(isA<StateError>()),
      );

      expect(engineer.calls, 0);
      expect(session.status, WorkspaceSessionStatus.ready);
      expect(session.hasChanges, isFalse);
      expect(workspaceGateway.writeCalls, 0);
      expect(workspaceGateway.deleteCalls, 0);
    });

    test('failed Engineer inference leaves workspace ready and unchanged',
        () async {
      final engineer = _StaticGateway(
        result: const WorkshopInferenceResult(
          text: '',
          terminalState: InferenceTerminalState.failed,
          errorMessage: 'engineer runtime failed',
        ),
      );
      final workspaceGateway = _RecordingWorkspaceGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final session = await _session(workspaceGateway);

      await expectLater(
        WorkshopProposalImplementationRunner(
          inference: _stageInference(_gateways(engineer)),
        ).run(session: session),
        throwsA(isA<StateError>()),
      );

      expect(session.status, WorkspaceSessionStatus.ready);
      expect(session.hasChanges, isFalse);
      expect(session.workspace.read('lib/app.dart'), 'old');
      expect(engineer.calls, 1);
      expect(workspaceGateway.writeCalls, 0);
      expect(workspaceGateway.deleteCalls, 0);
    });

    test('retries Engineer proposal with no file changes', () async {
      final engineer = _StaticGateway(
        results: <WorkshopInferenceResult>[
          const WorkshopInferenceResult(
            text: '{"explanation":"missing changes","changes":[]}',
            terminalState: InferenceTerminalState.success,
            model: 'engineer-model',
          ),
          const WorkshopInferenceResult(
            text:
                '{"explanation":"Recovered","changes":[{"path":"lib/app.dart","type":"modification","content":"new"}],"validationNotes":[],"warnings":[]}',
            terminalState: InferenceTerminalState.success,
            model: 'engineer-model',
          ),
        ],
      );
      final workspaceGateway = _RecordingWorkspaceGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final session = await _session(
        workspaceGateway,
        operation: WorkshopOperation.create,
      );

      final proposal = await WorkshopProposalImplementationRunner(
        inference: _stageInference(_gateways(engineer)),
      ).run(session: session);

      expect(proposal.explanation, 'Recovered');
      expect(proposal.changes.single.path, 'lib/app.dart');
      expect(session.workspace.read('lib/app.dart'), 'new');
      expect(engineer.calls, 2);
      expect(
        engineer.sessionIds,
        <String>[
          'workshop:implementation:implementation-runner-request',
          'workshop:implementation:implementation-runner-request:retry-malformed-1',
        ],
      );
      expect(engineer.maxTokensValues, <int?>[640, 768]);
      expect(
        engineer.prompts.last,
        contains(
          'Previous Engineer proposal was rejected before review: '
          'Workshop proposal must contain at least one file change.',
        ),
      );
      expect(engineer.prompts.last, contains('"operation":"create"'));
      expect(
        engineer.prompts.last,
        contains('Never return an empty changes'),
      );
      expect(
        engineer.systemPrompts.last,
        contains('targetFiles are a hard allowlist'),
      );
      expect(
        engineer.systemPrompts.last,
        contains('fold that behavior into an allowed target file'),
      );
      expect(workspaceGateway.writeCalls, 0);
      expect(workspaceGateway.deleteCalls, 0);
    });

    test('repairs empty proposal after a runtime retry', () async {
      final engineer = _StaticGateway(
        results: <WorkshopInferenceResult>[
          const WorkshopInferenceResult(
            text: '',
            terminalState: InferenceTerminalState.timeout,
            errorMessage: 'timeout',
            model: 'engineer-model',
          ),
          const WorkshopInferenceResult(
            text: '{"explanation":"missing changes","changes":[]}',
            terminalState: InferenceTerminalState.success,
            model: 'engineer-model',
          ),
          const WorkshopInferenceResult(
            text:
                '{"explanation":"Recovered after runtime retry","changes":[{"path":"lib/app.dart","type":"modification","content":"new"}],"validationNotes":[],"warnings":[]}',
            terminalState: InferenceTerminalState.success,
            model: 'engineer-model',
          ),
        ],
      );
      final workspaceGateway = _RecordingWorkspaceGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final session = await _session(workspaceGateway);

      final proposal = await WorkshopProposalImplementationRunner(
        inference: _stageInference(_gateways(engineer)),
      ).run(session: session);

      expect(proposal.explanation, 'Recovered after runtime retry');
      expect(session.workspace.read('lib/app.dart'), 'new');
      expect(engineer.calls, 3);
      expect(engineer.maxTokensValues, <int?>[640, 512, 768]);
      expect(
        engineer.sessionIds,
        <String>[
          'workshop:implementation:implementation-runner-request',
          'workshop:implementation:implementation-runner-request:retry-1',
          'workshop:implementation:implementation-runner-request:retry-malformed-1',
        ],
      );
      expect(workspaceGateway.writeCalls, 0);
      expect(workspaceGateway.deleteCalls, 0);
    });
  });
}

WorkshopStageRoleInference _stageInference(
  Map<AppAiRole, _StaticGateway> gateways,
) {
  return WorkshopStageRoleInference(
    executor: WorkshopRoleInferenceExecutor(
      router: WorkshopRoleInferenceRouter(gateways: gateways),
    ),
  );
}

Map<AppAiRole, _StaticGateway> _gateways(_StaticGateway engineer) {
  final idleResult = const WorkshopInferenceResult(
    text: '{}',
    terminalState: InferenceTerminalState.success,
  );

  return <AppAiRole, _StaticGateway>{
    AppAiRole.workshopOrchestrator: _StaticGateway(result: idleResult),
    AppAiRole.architect: _StaticGateway(result: idleResult),
    AppAiRole.engineer: engineer,
    AppAiRole.reviewer: _StaticGateway(result: idleResult),
  };
}

Future<WorkspaceSession> _session(
  _RecordingWorkspaceGateway gateway, {
  WorkshopOperation operation = WorkshopOperation.analyse,
}) async {
  final session = WorkspaceSession(
    request: WorkshopRequest(
      id: 'implementation-runner-request',
      title: 'Implement staged change',
      instruction: 'Update the app implementation safely',
      operation: operation,
      targetFiles: const <String>['lib/app.dart'],
      constraints: const <String>['Do not introduce regressions'],
    ),
    gateway: gateway,
  );

  await session.initialize();
  return session;
}

final class _StaticGateway extends WorkshopInferenceGateway {
  _StaticGateway({
    WorkshopInferenceResult? result,
    List<WorkshopInferenceResult>? results,
    Set<int> cancelTokenOnCalls = const <int>{},
  })  : _cancelTokenOnCalls = cancelTokenOnCalls,
        _results = results ??
            <WorkshopInferenceResult>[
              if (result != null) result,
            ],
        super(provider: _NoopProvider()) {
    if (_results.isEmpty) {
      throw ArgumentError('At least one inference result is required.');
    }
  }

  final List<WorkshopInferenceResult> _results;
  final Set<int> _cancelTokenOnCalls;
  int calls = 0;
  String? lastPrompt;
  final List<String> prompts = <String>[];
  final List<String?> systemPrompts = <String?>[];
  final List<String> sessionIds = <String>[];
  final List<int?> maxTokensValues = <int?>[];
  final List<bool> cancellationTokenWasNull = <bool>[];

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
    final index = calls;
    calls += 1;
    lastPrompt = prompt;
    prompts.add(prompt);
    systemPrompts.add(systemPrompt);
    sessionIds.add(sessionId);
    maxTokensValues.add(maxTokens);
    cancellationTokenWasNull.add(cancellationToken == null);
    if (_cancelTokenOnCalls.contains(index)) {
      cancellationToken?.cancel();
    }
    if (index >= _results.length) {
      throw StateError('Unexpected extra Engineer inference call.');
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
    return const Stream.empty();
  }
}

final class _RecordingWorkspaceGateway implements GitWorkspaceGateway {
  _RecordingWorkspaceGateway({required Map<String, String> files})
      : _files = Map<String, String>.from(files);

  final Map<String, String> _files;
  int writeCalls = 0;
  int deleteCalls = 0;
  int commitCalls = 0;
  int pushCalls = 0;
  int pullRequestCalls = 0;

  @override
  Future<GitWorkspaceInfo> openWorkspace() async => const GitWorkspaceInfo(
        repository: 'test/repository',
        branch: 'main',
      );

  @override
  Future<String?> readFile(String path) async => _files[path];

  @override
  Future<bool> fileExists(String path) async => _files.containsKey(path);

  @override
  Future<List<String>> listFiles({String? directory}) async =>
      _files.keys.toList(growable: false);

  @override
  Future<void> createBranch(String branchName) async {}

  @override
  Future<void> writeFile({required String path, required String content}) async {
    writeCalls += 1;
    _files[path] = content;
  }

  @override
  Future<void> deleteFile(String path) async {
    deleteCalls += 1;
    _files.remove(path);
  }

  @override
  Future<GitWorkspaceDiff> getDiff() async =>
      const GitWorkspaceDiff(files: <GitWorkspaceFileChange>[]);

  @override
  Future<String> commit(String message) async {
    commitCalls += 1;
    return 'commit';
  }

  @override
  Future<void> push() async {
    pushCalls += 1;
  }

  @override
  Future<String> createPullRequest({
    required String title,
    required String body,
    required String headBranch,
    required String baseBranch,
  }) async {
    pullRequestCalls += 1;
    return 'pr';
  }
}

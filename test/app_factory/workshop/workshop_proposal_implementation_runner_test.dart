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
      final preflight = WorkshopPreflightInferenceResult(
        analysis: const WorkshopInferenceResult(
          text: 'scope analysis from Orchestrator',
          terminalState: InferenceTerminalState.success,
        ),
        architecture: const WorkshopInferenceResult(
          text: 'bounded implementation plan from Architect',
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
        cancelTokenOnCalls: const <int>{0},
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
      expect(callerToken.isCancelled, isTrue);
      expect(
        engineer.sessionIds,
        <String>[
          'workshop:implementation:implementation-runner-request',
          'workshop:implementation:implementation-runner-request:retry-1',
        ],
      );
      expect(engineer.maxTokensValues, <int?>[640, 512]);
      expect(engineer.cancellationTokenWasNull, <bool>[false, true]);
      expect(engineer.prompts[1].length, lessThan(engineer.prompts[0].length));
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

    test('retries valid JSON that omits required explanation', () async {
      final engineer = _StaticGateway(
        results: <WorkshopInferenceResult>[
          const WorkshopInferenceResult(
            text:
                '{"summary":"Walking MVP","changes":[{"path":"lib/app.dart","type":"modification","content":"new"}],"validationNotes":[],"warnings":[]}',
            terminalState: InferenceTerminalState.success,
            model: 'engineer-model',
          ),
          const WorkshopInferenceResult(
            text:
                '{"summary":"Walking MVP","explanation":"Complete the bounded walking MVP","changes":[{"path":"lib/app.dart","type":"modification","content":"new"}],"validationNotes":[],"warnings":[]}',
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

      expect(proposal.explanation, 'Complete the bounded walking MVP');
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
        engineer.prompts[1],
        contains('"explanation":"required"'),
      );
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

    test('malformed Engineer output is not materialized', () async {
      final engineer = _StaticGateway(
        result: const WorkshopInferenceResult(
          text: '{"explanation":"missing changes","changes":[]}',
          terminalState: InferenceTerminalState.success,
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
        throwsA(isA<FormatException>()),
      );

      expect(session.status, WorkspaceSessionStatus.ready);
      expect(session.hasChanges, isFalse);
      expect(session.workspace.read('lib/app.dart'), 'old');
      expect(engineer.calls, 1);
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

Future<WorkspaceSession> _session(_RecordingWorkspaceGateway gateway) async {
  final session = WorkspaceSession(
    request: const WorkshopRequest(
      id: 'implementation-runner-request',
      title: 'Implement staged change',
      instruction: 'Update the app implementation safely',
      targetFiles: <String>['lib/app.dart'],
      constraints: <String>['Do not introduce regressions'],
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

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
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

      final proposal = await WorkshopProposalImplementationRunner(
        inference: _stageInference(gateways),
      ).run(session: session);

      expect(proposal.changes, hasLength(1));
      expect(session.workspace.read('lib/app.dart'), 'new');
      expect(session.status, WorkspaceSessionStatus.review);
      expect(session.isApplyApproved, isFalse);
      expect(engineer.calls, 1);
      expect(engineer.lastPrompt, contains('"lib/app.dart":"old"'));
      expect(gateways[AppAiRole.workshopOrchestrator]!.calls, 0);
      expect(gateways[AppAiRole.architect]!.calls, 0);
      expect(gateways[AppAiRole.reviewer]!.calls, 0);
      expect(workspaceGateway.writeCalls, 0);
      expect(workspaceGateway.deleteCalls, 0);
      expect(workspaceGateway.commitCalls, 0);
      expect(workspaceGateway.pushCalls, 0);
      expect(workspaceGateway.pullRequestCalls, 0);
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
  _StaticGateway({required this.result}) : super(provider: _NoopProvider());

  final WorkshopInferenceResult result;
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
    return result;
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

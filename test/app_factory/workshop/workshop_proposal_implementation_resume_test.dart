import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_implementation_runner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_resume_context.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_router.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';

void main() {
  test('Engineer resumes from semantic context with stable execution identity',
      () async {
    final provider = _RecordingProvider();
    final stageInference = WorkshopStageRoleInference(
      executor: WorkshopRoleInferenceExecutor(
        router: WorkshopRoleInferenceRouter(
          gateways: <AppAiRole, WorkshopInferenceGateway>{
            for (final role in WorkshopRoleInferenceRouter.workshopRoles)
              role: WorkshopInferenceGateway(provider: provider),
          },
        ),
      ),
    );
    final workspaceGateway = _MemoryWorkspaceGateway(
      files: <String, String>{'lib/app.dart': 'old'},
    );
    final session = WorkspaceSession(
      request: const WorkshopRequest(
        id: 'request-resume-1',
        title: 'Continue implementation',
        instruction: 'Finish the prepared change',
        targetFiles: <String>['lib/app.dart'],
        constraints: <String>['Keep compatibility'],
      ),
      gateway: workspaceGateway,
    );
    await session.initialize();

    const resume = WorkshopResumeContext(
      executionId: 'execution-stable',
      attemptId: 'attempt-2',
      projectId: 'project-1',
      taskId: 'task-7',
      sessionId: 'session-1',
      objective: 'Finish the implementation safely',
      phase: 'implementation',
      checkpointId: 'checkpoint-3',
      completedSteps: <String>['inspected existing implementation'],
      changedFiles: <String>['lib/app.dart'],
      decisions: <String>['preserve public API'],
      verified: <String>['baseline tests passed'],
      remainingWork: <String>['finish app change'],
      nextStep: 'update lib/app.dart',
    );

    final proposal = await WorkshopProposalImplementationRunner(
      inference: stageInference,
    ).runWithResumeContext(
      session: session,
      resumeContext: resume,
    );

    expect(proposal.changes, hasLength(1));
    expect(provider.lastRequest, isNotNull);
    expect(provider.lastRequest!.sessionId, 'session-1');
    expect(provider.lastRequest!.requestId, 'request-resume-1');
    expect(provider.lastRequest!.projectId, 'project-1');
    expect(provider.lastRequest!.taskId, 'task-7');
    expect(provider.lastRequest!.executionId, 'execution-stable');
    expect(provider.lastRequest!.attemptId, 'attempt-2');
    expect(provider.lastRequest!.checkpointId, 'checkpoint-3');
    expect(
      provider.lastRequest!.prompt,
      contains('inspected existing implementation'),
    );
    expect(provider.lastRequest!.prompt, contains('preserve public API'));
    expect(provider.lastRequest!.prompt, contains('baseline tests passed'));
    expect(provider.lastRequest!.prompt, contains('update lib/app.dart'));
    expect(session.workspace.read('lib/app.dart'), 'new');
    expect(session.status, WorkspaceSessionStatus.review);
    expect(workspaceGateway.writeCalls, 0);
  });
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
        InferenceResponse(
          text:
              '{"summary":"Resume","explanation":"Continue from checkpoint","changes":[{"path":"lib/app.dart","type":"modification","content":"new"}],"validationNotes":[],"warnings":[]}',
          timestamp: 1,
        ),
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

final class _MemoryWorkspaceGateway implements GitWorkspaceGateway {
  _MemoryWorkspaceGateway({required Map<String, String> files})
      : _files = Map<String, String>.from(files);

  final Map<String, String> _files;
  int writeCalls = 0;

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
    _files.remove(path);
  }

  @override
  Future<GitWorkspaceDiff> getDiff() async =>
      const GitWorkspaceDiff(files: <GitWorkspaceFileChange>[]);

  @override
  Future<String> commit(String message) async => 'commit';

  @override
  Future<void> push() async {}

  @override
  Future<String> createPullRequest({
    required String title,
    required String body,
    required String headBranch,
    required String baseBranch,
  }) async => 'pr';
}

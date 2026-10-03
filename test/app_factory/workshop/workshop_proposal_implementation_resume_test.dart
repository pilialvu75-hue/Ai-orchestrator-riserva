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
    expect(provider.lastRequest!.maxTokens, 640);
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

  for (final mode in <String>[
    'recover',
    'repeat',
    'cancelled',
    'unavailable',
    'caller_cancelled'
  ]) {
    test('resume prompt-budget $mode keeps identity and bounds', () async {
      final provider = _PromptBudgetProvider(mode);
      final inference = WorkshopStageRoleInference(
          executor: WorkshopRoleInferenceExecutor(
        router: WorkshopRoleInferenceRouter(
            gateways: <AppAiRole, WorkshopInferenceGateway>{
              for (final role in WorkshopRoleInferenceRouter.workshopRoles)
                role: WorkshopInferenceGateway(provider: provider),
            }),
      ));
      final gateway = _MemoryWorkspaceGateway(
          files: <String, String>{'lib/app.dart': 'old'});
      final session = WorkspaceSession(
          request: const WorkshopRequest(
            id: 'request-budget',
            title: 'Continue',
            instruction: 'Finish the change',
            targetFiles: <String>['lib/app.dart'],
          ),
          gateway: gateway);
      await session.initialize();
      final resume = WorkshopResumeContext(
        executionId: 'execution-budget',
        attemptId: 'attempt-budget',
        projectId: 'project-budget',
        taskId: 'task-budget',
        sessionId: 'session-budget',
        checkpointId: 'checkpoint-budget',
        objective: 'Finish safely',
        phase: 'implementation',
        completedSteps: <String>['completed ' * 3000],
        remainingWork: <String>['remaining ' * 3000],
        verified: <String>['verified ' * 3000],
      );
      final token = CancellationToken();
      if (mode == 'caller_cancelled') token.cancel();
      final future = WorkshopProposalImplementationRunner(inference: inference)
          .runWithResumeContext(
              session: session,
              resumeContext: resume,
              cancellationToken: token);
      if (mode == 'recover') {
        final proposal = await future;
        expect(proposal.changes.single.path, 'lib/app.dart');
        expect(session.workspace.read('lib/app.dart'), 'recovered');
        expect(session.status, WorkspaceSessionStatus.review);
      } else {
        await expectLater(future, throwsStateError);
        expect(session.workspace.read('lib/app.dart'), 'old');
        expect(session.hasChanges, isFalse);
      }
      final retry = mode == 'recover' || mode == 'repeat';
      expect(provider.requests, hasLength(retry ? 2 : 1));
      if (retry) {
        expect(provider.requests.last.sessionId,
            'session-budget:engineer-retry-1');
        expect(provider.requests.last.maxTokens, 512);
        expect(provider.requests.last.prompt.length, lessThan(4000));
        expect(
            provider.requests.last.prompt, isNot(contains('remaining ' * 100)));
      }
      for (final request in provider.requests) {
        expect(request.requestId, 'request-budget');
        expect(request.projectId, 'project-budget');
        expect(request.taskId, 'task-budget');
        expect(request.executionId, 'execution-budget');
        expect(request.attemptId, 'attempt-budget');
        expect(request.checkpointId, 'checkpoint-budget');
      }
      expect(session.isApplyApproved, isFalse);
      expect(gateway.writeCalls, 0);
    });
  }

  test('resume path reuses summary when Engineer omits explanation', () async {
    final provider = _RetryRecordingProvider();
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
        id: 'request-resume-schema',
        title: 'Repair walking MVP',
        instruction: 'Finish the bounded walking MVP',
        targetFiles: <String>['lib/app.dart'],
      ),
      gateway: workspaceGateway,
    );
    await session.initialize();

    const resume = WorkshopResumeContext(
      executionId: 'execution-schema',
      attemptId: 'attempt-schema',
      projectId: 'project-schema',
      taskId: 'task-schema',
      sessionId: 'session-schema',
      objective: 'Repair the staged proposal',
      phase: 'implementation',
    );

    final proposal = await WorkshopProposalImplementationRunner(
      inference: stageInference,
    ).runWithResumeContext(
      session: session,
      resumeContext: resume,
      revisionFeedback: 'Reviewer requested a complete bounded implementation.',
      revisionAttempt: 1,
    );

    expect(proposal.explanation, 'Repair');
    expect(session.workspace.read('lib/app.dart'), 'repaired');
    expect(provider.requests, hasLength(1));
    expect(
      provider.requests.map((request) => request.sessionId).toList(),
      <String>['session-schema:revision-1'],
    );
    expect(
      provider.requests.map((request) => request.maxTokens).toList(),
      <int?>[640],
    );
    expect(
      provider.requests
          .every((request) => request.executionId == 'execution-schema'),
      isTrue,
    );
    expect(
      provider.requests.every((request) => request.taskId == 'task-schema'),
      isTrue,
    );
    expect(workspaceGateway.writeCalls, 0);
  });

  test(
      'resume path repairs empty proposal after runtime retry with stable identity',
      () async {
    final provider = _ResumeThreeCallProvider();
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
        id: 'request-resume-three-call',
        title: 'Recover implementation',
        instruction: 'Finish the prepared change',
        targetFiles: <String>['lib/app.dart'],
      ),
      gateway: workspaceGateway,
    );
    await session.initialize();

    const resume = WorkshopResumeContext(
      executionId: 'execution-three-call',
      attemptId: 'attempt-three-call',
      projectId: 'project-three-call',
      taskId: 'task-three-call',
      sessionId: 'session-three-call',
      objective: 'Recover the implementation safely',
      phase: 'implementation',
      checkpointId: 'checkpoint-three-call',
    );

    final proposal = await WorkshopProposalImplementationRunner(
      inference: stageInference,
    ).runWithResumeContext(session: session, resumeContext: resume);

    expect(proposal.explanation, 'Recovered');
    expect(session.workspace.read('lib/app.dart'), 'recovered');
    expect(provider.requests, hasLength(3));
    expect(
      provider.requests.map((request) => request.maxTokens).toList(),
      <int?>[640, 512, 768],
    );
    expect(
      provider.requests.map((request) => request.sessionId).toList(),
      <String>[
        'session-three-call',
        'session-three-call:engineer-retry-1',
        'session-three-call:engineer-retry-malformed-1',
      ],
    );
    for (final request in provider.requests) {
      expect(request.requestId, 'request-resume-three-call');
      expect(request.projectId, 'project-three-call');
      expect(request.taskId, 'task-three-call');
      expect(request.executionId, 'execution-three-call');
      expect(request.attemptId, 'attempt-three-call');
      expect(request.checkpointId, 'checkpoint-three-call');
    }
    expect(workspaceGateway.writeCalls, 0);
  });
}

final class _PromptBudgetProvider implements RuntimeInferenceProvider {
  _PromptBudgetProvider(this.mode);
  final String mode;
  final List<InferenceRequest> requests = <InferenceRequest>[];

  @override
  TokenStream streamInference(
      {required InferenceRequest request,
      required CancellationToken cancellationToken}) {
    requests.add(request);
    if (requests.length == 1 || mode == 'repeat') {
      return Stream<InferenceResponse>.value(InferenceResponse.error(
        'AI_RUNTIME_ERROR|stage=prompt_budget|message=Prompt exceeds the local context capacity.',
        state: mode == 'cancelled'
            ? InferenceTerminalState.cancelled
            : mode == 'unavailable'
                ? InferenceTerminalState.modelUnavailable
                : InferenceTerminalState.failed,
      ));
    }
    return Stream<InferenceResponse>.value(const InferenceResponse(
      text:
          '{"explanation":"Recovered","changes":[{"path":"lib/app.dart","type":"modification","content":"recovered"}]}',
      timestamp: 1,
      isFinal: true,
      terminalState: InferenceTerminalState.success,
    ));
  }
}

final class _ResumeThreeCallProvider implements RuntimeInferenceProvider {
  final List<InferenceRequest> requests = <InferenceRequest>[];

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) {
    final index = requests.length;
    requests.add(request);
    if (index == 0) {
      return Stream<InferenceResponse>.value(
        const InferenceResponse(
          text: '',
          timestamp: 1,
          isFinal: true,
          terminalState: InferenceTerminalState.timeout,
          errorMessage: 'timeout',
        ),
      );
    }
    final text = index == 1
        ? '{"explanation":"missing changes","changes":[]}'
        : '{"explanation":"Recovered","changes":[{"path":"lib/app.dart","type":"modification","content":"recovered"}],"validationNotes":[],"warnings":[]}';
    return Stream<InferenceResponse>.fromIterable(
      <InferenceResponse>[
        InferenceResponse(text: text, timestamp: 1),
        const InferenceResponse(
          text: '',
          timestamp: 2,
          isFinal: true,
          terminalState: InferenceTerminalState.success,
        ),
      ],
    );
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

final class _RetryRecordingProvider implements RuntimeInferenceProvider {
  final List<InferenceRequest> requests = <InferenceRequest>[];

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) {
    final index = requests.length;
    requests.add(request);
    final text = index == 0
        ? '{"summary":"Repair","changes":[{"path":"lib/app.dart","type":"modification","content":"repaired"}],"validationNotes":[],"warnings":[]}'
        : '{"summary":"Repair","explanation":"Repair completed","changes":[{"path":"lib/app.dart","type":"modification","content":"repaired"}],"validationNotes":[],"warnings":[]}';
    return Stream<InferenceResponse>.fromIterable(
      <InferenceResponse>[
        InferenceResponse(text: text, timestamp: 1),
        const InferenceResponse(
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
  Future<void> writeFile(
      {required String path, required String content}) async {
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
  }) async =>
      'pr';
}

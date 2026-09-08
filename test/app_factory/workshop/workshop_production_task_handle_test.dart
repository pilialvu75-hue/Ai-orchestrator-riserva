import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_apply_approval_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_lifecycle_bundle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_task_handle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_resume_context.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

void main() {
  test('production task handle keeps one session through approval and apply',
      () async {
    final workspaceGateway = _RecordingWorkspaceGateway(
      files: <String, String>{'lib/app.dart': 'old'},
    );
    final executor = WorkshopProjectExecutor(gateway: workspaceGateway);
    final calls = <AppAiRole>[];
    final bundle = WorkshopProductionLifecycleBundleFactory.create(
      projectExecutor: executor,
      roleGateways: _gateways(calls),
    );
    final coordinator = WorkshopProductionTaskCoordinator(bundle: bundle);

    final handle = await coordinator.startAndPrepare(
      title: 'Handle test',
      instruction: 'Update the application safely.',
    );

    final requestId = bundle.dashboardController.state.requestId;

    expect(requestId, isNotNull);
    expect(handle.taskId, 'task:initial-implementation');
    expect(identical(executor.sessionForTask(handle.taskId), handle.session), isTrue);
    expect(workspaceGateway.writeCalls, 0);

    final inference = await coordinator.runPrepared(handle: handle);

    expect(inference.readyForApproval, isTrue);
    expect(workspaceGateway.files['lib/app.dart'], 'old');
    expect(workspaceGateway.writeCalls, 0);
    expect(
      calls,
      <AppAiRole>[
        AppAiRole.workshopOrchestrator,
        AppAiRole.architect,
        AppAiRole.engineer,
        AppAiRole.reviewer,
        AppAiRole.reviewer,
      ],
    );

    final approved = coordinator.decide(
      handle: handle,
      decision: WorkshopApplyDecision.approve,
    );

    expect(identical(approved, handle.session), isTrue);
    expect(workspaceGateway.writeCalls, 0);

    final applied = await coordinator.applyApproved(handle: handle);

    expect(identical(applied, handle.session), isTrue);
    expect(workspaceGateway.files['lib/app.dart'], 'new');
    expect(workspaceGateway.writeCalls, 1);
    expect(workspaceGateway.commitCalls, 0);
    expect(workspaceGateway.pushCalls, 0);
    expect(workspaceGateway.pullRequestCalls, 0);

    final dashboardState = bundle.dashboardController.state;

    expect(dashboardState.projectStatus, WorkshopProjectStatus.completed);
    expect(dashboardState.progress, 1.0);
    expect(dashboardState.completedTasks, 1);
    expect(dashboardState.totalTasks, 1);
    expect(dashboardState.activeTaskId, isNull);
    expect(
      bundle.dashboardController.engine.stageOf(requestId!),
      WorkshopStage.completed,
    );
  });

  test('coordinator recovers the exact task already prepared by dashboard',
      () async {
    final workspaceGateway = _RecordingWorkspaceGateway(
      files: <String, String>{'lib/app.dart': 'old'},
    );
    final executor = WorkshopProjectExecutor(gateway: workspaceGateway);
    final bundle = WorkshopProductionLifecycleBundleFactory.create(
      projectExecutor: executor,
      roleGateways: _gateways(<AppAiRole>[]),
    );
    final coordinator = WorkshopProductionTaskCoordinator(bundle: bundle);

    final plan = bundle.dashboardController.startProduction(
      title: 'Dashboard prepared task',
      instruction: 'Prepare through the existing dashboard flow.',
    );
    final session = await bundle.dashboardController.prepareNextTask();

    expect(session, isNotNull);

    final handle = coordinator.preparedHandle();

    expect(identical(handle.plan, plan), isTrue);
    expect(handle.taskId, 'task:initial-implementation');
    expect(identical(handle.session, session), isTrue);
    expect(identical(executor.sessionForTask(handle.taskId), handle.session), isTrue);
    expect(workspaceGateway.writeCalls, 0);
    expect(workspaceGateway.commitCalls, 0);
    expect(workspaceGateway.pushCalls, 0);
    expect(workspaceGateway.pullRequestCalls, 0);
  });

  test('production coordinator resumes same task and forwards stable identity',
      () async {
    final workspaceGateway = _RecordingWorkspaceGateway(
      files: <String, String>{'lib/app.dart': 'old'},
    );
    final executor = WorkshopProjectExecutor(gateway: workspaceGateway);
    final calls = <AppAiRole>[];
    final engineer = _QueueGateway(
      role: AppAiRole.engineer,
      calls: calls,
      results: <WorkshopInferenceResult>[_success(_proposalJson)],
    );
    final reviewer = _QueueGateway(
      role: AppAiRole.reviewer,
      calls: calls,
      results: <WorkshopInferenceResult>[
        _success(_approvedReviewJson),
        _success(_validValidationJson),
      ],
    );
    final bundle = WorkshopProductionLifecycleBundleFactory.create(
      projectExecutor: executor,
      roleGateways: <AppAiRole, WorkshopInferenceGateway>{
        AppAiRole.workshopOrchestrator: _QueueGateway(
          role: AppAiRole.workshopOrchestrator,
          calls: calls,
          results: <WorkshopInferenceResult>[_success('{}')],
        ),
        AppAiRole.architect: _QueueGateway(
          role: AppAiRole.architect,
          calls: calls,
          results: <WorkshopInferenceResult>[_success('{}')],
        ),
        AppAiRole.engineer: engineer,
        AppAiRole.reviewer: reviewer,
      },
    );
    final coordinator = WorkshopProductionTaskCoordinator(bundle: bundle);
    final handle = await coordinator.startAndPrepare(
      title: 'Resume handle test',
      instruction: 'Continue the application change safely.',
    );

    const resume = WorkshopResumeContext(
      executionId: 'execution-stable',
      attemptId: 'attempt-2',
      projectId: 'project-1',
      taskId: 'task:initial-implementation',
      sessionId: 'workshop-session-1',
      objective: 'Continue implementation safely',
      phase: 'implementation',
      checkpointId: 'checkpoint-4',
      completedSteps: <String>['analysis complete'],
      changedFiles: <String>['lib/app.dart'],
      decisions: <String>['preserve public API'],
      verified: <String>['baseline tests passed'],
      remainingWork: <String>['finish implementation'],
      nextStep: 'update lib/app.dart',
    );

    final result = await coordinator.runPreparedWithResumeContext(
      handle: handle,
      resumeContext: resume,
    );

    expect(result.readyForApproval, isTrue);
    expect(identical(executor.sessionForTask(handle.taskId), handle.session), isTrue);
    expect(workspaceGateway.files['lib/app.dart'], 'old');
    expect(workspaceGateway.writeCalls, 0);
    expect(
      calls,
      <AppAiRole>[
        AppAiRole.workshopOrchestrator,
        AppAiRole.architect,
        AppAiRole.engineer,
        AppAiRole.reviewer,
        AppAiRole.reviewer,
      ],
    );
    expect(engineer.lastIdentity, isNotNull);
    expect(engineer.lastIdentity!['executionId'], 'execution-stable');
    expect(engineer.lastIdentity!['attemptId'], 'attempt-2');
    expect(engineer.lastIdentity!['taskId'], 'task:initial-implementation');
    expect(engineer.lastIdentity!['projectId'], 'project-1');
    expect(engineer.lastIdentity!['checkpointId'], 'checkpoint-4');
    expect(engineer.lastIdentity!['sessionId'], 'workshop-session-1');
    expect(engineer.lastPrompt, contains('analysis complete'));
    expect(engineer.lastPrompt, contains('preserve public API'));
    expect(engineer.lastPrompt, contains('baseline tests passed'));
    expect(engineer.lastPrompt, contains('update lib/app.dart'));
  });
}

const String _proposalJson =
    '{"summary":"Update app","explanation":"Implement requested change",'
    '"changes":[{"path":"lib/app.dart","type":"modification",'
    '"content":"new"}],"validationNotes":[],"warnings":[]}';
const String _approvedReviewJson =
    '{"approved":true,"summary":"Review passed","findings":[],"warnings":[]}';
const String _validValidationJson =
    '{"valid":true,"summary":"Validation passed","checks":["consistent"],'
    '"warnings":[]}';

Map<AppAiRole, WorkshopInferenceGateway> _gateways(List<AppAiRole> calls) =>
    <AppAiRole, WorkshopInferenceGateway>{
      AppAiRole.workshopOrchestrator: _QueueGateway(
        role: AppAiRole.workshopOrchestrator,
        calls: calls,
        results: <WorkshopInferenceResult>[_success('{}')],
      ),
      AppAiRole.architect: _QueueGateway(
        role: AppAiRole.architect,
        calls: calls,
        results: <WorkshopInferenceResult>[_success('{}')],
      ),
      AppAiRole.engineer: _QueueGateway(
        role: AppAiRole.engineer,
        calls: calls,
        results: <WorkshopInferenceResult>[_success(_proposalJson)],
      ),
      AppAiRole.reviewer: _QueueGateway(
        role: AppAiRole.reviewer,
        calls: calls,
        results: <WorkshopInferenceResult>[
          _success(_approvedReviewJson),
          _success(_validValidationJson),
        ],
      ),
    };

WorkshopInferenceResult _success(String text) => WorkshopInferenceResult(
      text: text,
      terminalState: InferenceTerminalState.success,
    );

final class _QueueGateway extends WorkshopInferenceGateway {
  _QueueGateway({
    required this.role,
    required this.calls,
    required List<WorkshopInferenceResult> results,
  })  : _results = List<WorkshopInferenceResult>.from(results),
        super(provider: _NoopProvider());

  final AppAiRole role;
  final List<AppAiRole> calls;
  final List<WorkshopInferenceResult> _results;
  Map<String, String?>? lastIdentity;
  String? lastPrompt;

  WorkshopInferenceResult _nextResult(String prompt) {
    calls.add(role);
    lastPrompt = prompt;
    if (_results.isEmpty) {
      throw StateError('No queued result for ${role.id}.');
    }
    return _results.removeAt(0);
  }

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
  }) async =>
      _nextResult(prompt);

  @override
  Future<WorkshopInferenceResult> completeWithIdentity({
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
    String? requestId,
    String? projectId,
    String? taskId,
    String? executionId,
    String? attemptId,
    String? checkpointId,
    CancellationToken? cancellationToken,
  }) async {
    lastIdentity = <String, String?>{
      'requestId': requestId,
      'projectId': projectId,
      'taskId': taskId,
      'executionId': executionId,
      'attemptId': attemptId,
      'checkpointId': checkpointId,
      'sessionId': sessionId,
    };
    return _nextResult(prompt);
  }
}

final class _NoopProvider implements RuntimeInferenceProvider {
  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) => const Stream.empty();
}

final class _RecordingWorkspaceGateway implements GitWorkspaceGateway {
  _RecordingWorkspaceGateway({required Map<String, String> files})
      : files = Map<String, String>.from(files);

  final Map<String, String> files;
  int writeCalls = 0;
  int commitCalls = 0;
  int pushCalls = 0;
  int pullRequestCalls = 0;

  @override
  Future<GitWorkspaceInfo> openWorkspace() async => const GitWorkspaceInfo(
        repository: 'test/repository',
        branch: 'main',
      );

  @override
  Future<String?> readFile(String path) async => files[path];

  @override
  Future<bool> fileExists(String path) async => files.containsKey(path);

  @override
  Future<List<String>> listFiles({String? directory}) async =>
      files.keys.toList(growable: false);

  @override
  Future<void> createBranch(String branchName) async {}

  @override
  Future<void> writeFile({required String path, required String content}) async {
    writeCalls += 1;
    files[path] = content;
  }

  @override
  Future<void> deleteFile(String path) async {
    files.remove(path);
  }

  @override
  Future<GitWorkspaceDiff> getDiff() async => const GitWorkspaceDiff(
        files: <GitWorkspaceFileChange>[],
      );

  @override
  Future<String> commit(String message) async {
    commitCalls += 1;
    return 'test-commit-sha';
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
    return 'https://example.invalid/pull/1';
  }
}

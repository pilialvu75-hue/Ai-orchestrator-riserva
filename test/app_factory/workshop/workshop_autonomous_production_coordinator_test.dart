import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_autonomous_production_coordinator.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_lifecycle_bundle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_executor.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

void main() {
  test('default autonomous policy stops before real workspace apply', () async {
    final workspace = _RecordingWorkspaceGateway(
      files: <String, String>{'lib/app.dart': 'old'},
    );
    final build = _RecordingBuildProvider();
    final bundle = _bundle(
      workspace: workspace,
      build: build,
      gateways: _approvedGateways(),
    );

    final result = await WorkshopAutonomousProductionCoordinator(
      bundle: bundle,
    ).runNewProduction(
      title: 'Guarded autonomous run',
      instruction: 'Update the application safely.',
      target: WorkshopBuildTarget.android,
    );

    expect(
      result.status,
      WorkshopAutonomousProductionStatus.awaitingApproval,
    );
    expect(result.taskResults, hasLength(1));
    expect(result.taskResults.single.readyForApproval, isTrue);
    expect(workspace.files['lib/app.dart'], 'old');
    expect(workspace.writeCalls, 0);
    expect(build.buildCalls, 0);
  });

  test('explicit autonomous apply completes task and final artifact build',
      () async {
    final workspace = _RecordingWorkspaceGateway(
      files: <String, String>{'lib/app.dart': 'old'},
    );
    final build = _RecordingBuildProvider();
    final bundle = _bundle(
      workspace: workspace,
      build: build,
      gateways: _approvedGateways(),
    );

    final result = await WorkshopAutonomousProductionCoordinator(
      bundle: bundle,
      policy: const WorkshopAutonomousProductionPolicy(
        allowRealWorkspaceApply: true,
      ),
    ).runNewProduction(
      title: 'Autonomous artifact run',
      instruction: 'Update the application and produce an APK.',
      target: WorkshopBuildTarget.android,
    );

    expect(result.status, WorkshopAutonomousProductionStatus.completed);
    expect(result.succeeded, isTrue);
    expect(result.plan.isComplete, isTrue);
    expect(result.taskResults, hasLength(1));
    expect(workspace.files['lib/app.dart'], 'new');
    expect(workspace.writeCalls, 1);
    expect(build.buildCalls, 1);
    expect(result.buildResult?.hasArtifact, isTrue);
    expect(build.lastRequest?.target, WorkshopBuildTarget.android);
  });

  test('review rejection blocks apply and build', () async {
    final workspace = _RecordingWorkspaceGateway(
      files: <String, String>{'lib/app.dart': 'old'},
    );
    final build = _RecordingBuildProvider();
    final bundle = _bundle(
      workspace: workspace,
      build: build,
      gateways: _rejectedGateways(),
    );

    final result = await WorkshopAutonomousProductionCoordinator(
      bundle: bundle,
      policy: const WorkshopAutonomousProductionPolicy(
        allowRealWorkspaceApply: true,
      ),
    ).runNewProduction(
      title: 'Rejected autonomous run',
      instruction: 'Attempt a change that reviewer rejects.',
      target: WorkshopBuildTarget.android,
    );

    expect(
      result.status,
      WorkshopAutonomousProductionStatus.blockedByReview,
    );
    expect(workspace.files['lib/app.dart'], 'old');
    expect(workspace.writeCalls, 0);
    expect(build.buildCalls, 0);
  });

  test('offline autonomous production forces offline-local final build',
      () async {
    final workspace = _RecordingWorkspaceGateway(
      files: <String, String>{'lib/app.dart': 'old'},
    );
    final build = _RecordingBuildProvider();
    final gateways = _approvedGateways();
    final bundle = _bundle(
      workspace: workspace,
      build: build,
      gateways: gateways,
    );

    final result = await WorkshopAutonomousProductionCoordinator(
      bundle: bundle,
      policy: const WorkshopAutonomousProductionPolicy(
        allowRealWorkspaceApply: true,
      ),
    ).runNewProduction(
      title: 'Offline autonomous run',
      instruction: 'Complete this production without network access.',
      target: WorkshopBuildTarget.android,
      isOffline: true,
      buildMode: WorkshopBuildExecutionMode.remote,
    );

    expect(result.status, WorkshopAutonomousProductionStatus.completed);
    expect(build.lastRequest?.mode, WorkshopBuildExecutionMode.offlineLocal);
    expect(
      gateways.values.whereType<_QueueGateway>().every(
            (gateway) => gateway.lastIsOffline == true,
          ),
      isTrue,
    );
  });
}

WorkshopProductionLifecycleBundle _bundle({
  required _RecordingWorkspaceGateway workspace,
  required _RecordingBuildProvider build,
  required Map<AppAiRole, WorkshopInferenceGateway> gateways,
}) {
  final executor = WorkshopProjectExecutor(gateway: workspace);
  final buildLab = WorkshopBuildLab(
    providers: <WorkshopBuildProvider>[build],
  );
  final base = WorkshopProductionLifecycleBundleFactory.create(
    projectExecutor: executor,
    roleGateways: gateways,
    buildLab: buildLab,
  );

  return WorkshopProductionLifecycleBundle(
    dashboardController: base.dashboardController,
    preflight: base.preflight,
    taskLifecycle: base.taskLifecycle,
    projectExecutor: base.projectExecutor,
    workspaceRootPath: '/tmp/workshop-autonomous-project',
  );
}

const String _proposalJson =
    '{"summary":"Update app","explanation":"Implement requested change",'
    '"changes":[{"path":"lib/app.dart","type":"modification",'
    '"content":"new"}],"validationNotes":[],"warnings":[]}';
const String _approvedReviewJson =
    '{"approved":true,"summary":"Review passed","findings":[],"warnings":[]}';
const String _rejectedReviewJson =
    '{"approved":false,"summary":"Review rejected","findings":["unsafe"],'
    '"warnings":[]}';
const String _validValidationJson =
    '{"valid":true,"summary":"Validation passed","checks":["consistent"],'
    '"warnings":[]}';

Map<AppAiRole, WorkshopInferenceGateway> _approvedGateways() =>
    <AppAiRole, WorkshopInferenceGateway>{
      AppAiRole.workshopOrchestrator: _QueueGateway(
        role: AppAiRole.workshopOrchestrator,
        results: <WorkshopInferenceResult>[_success('{}')],
      ),
      AppAiRole.architect: _QueueGateway(
        role: AppAiRole.architect,
        results: <WorkshopInferenceResult>[_success('{}')],
      ),
      AppAiRole.engineer: _QueueGateway(
        role: AppAiRole.engineer,
        results: <WorkshopInferenceResult>[_success(_proposalJson)],
      ),
      AppAiRole.reviewer: _QueueGateway(
        role: AppAiRole.reviewer,
        results: <WorkshopInferenceResult>[
          _success(_approvedReviewJson),
          _success(_validValidationJson),
        ],
      ),
    };

Map<AppAiRole, WorkshopInferenceGateway> _rejectedGateways() =>
    <AppAiRole, WorkshopInferenceGateway>{
      AppAiRole.workshopOrchestrator: _QueueGateway(
        role: AppAiRole.workshopOrchestrator,
        results: <WorkshopInferenceResult>[_success('{}')],
      ),
      AppAiRole.architect: _QueueGateway(
        role: AppAiRole.architect,
        results: <WorkshopInferenceResult>[_success('{}')],
      ),
      AppAiRole.engineer: _QueueGateway(
        role: AppAiRole.engineer,
        results: <WorkshopInferenceResult>[_success(_proposalJson)],
      ),
      AppAiRole.reviewer: _QueueGateway(
        role: AppAiRole.reviewer,
        results: <WorkshopInferenceResult>[_success(_rejectedReviewJson)],
      ),
    };

WorkshopInferenceResult _success(String text) => WorkshopInferenceResult(
      text: text,
      terminalState: InferenceTerminalState.success,
    );

final class _QueueGateway extends WorkshopInferenceGateway {
  _QueueGateway({
    required this.role,
    required List<WorkshopInferenceResult> results,
  })  : _results = List<WorkshopInferenceResult>.from(results),
        super(provider: _NoopProvider());

  final AppAiRole role;
  final List<WorkshopInferenceResult> _results;
  bool? lastIsOffline;

  WorkshopInferenceResult _next(bool isOffline) {
    lastIsOffline = isOffline;
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
    bool isOffline = false,
    int? maxTokens,
    double? temperature,
    double topP = 0.9,
    double repeatPenalty = 1.1,
    String? modelId,
    String? modelPath,
    CancellationToken? cancellationToken,
  }) async =>
      _next(isOffline);

  @override
  Future<WorkshopInferenceResult> completeWithIdentity({
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
    String? requestId,
    String? projectId,
    String? taskId,
    String? executionId,
    String? attemptId,
    String? checkpointId,
    CancellationToken? cancellationToken,
  }) async =>
      _next(isOffline);
}

final class _NoopProvider implements RuntimeInferenceProvider {
  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) => const Stream.empty();
}

final class _RecordingBuildProvider implements WorkshopBuildProvider {
  int buildCalls = 0;
  WorkshopBuildRequest? lastRequest;

  @override
  WorkshopBuildExecutionMode get executionMode =>
      WorkshopBuildExecutionMode.offlineLocal;

  @override
  Future<WorkshopToolchainInfo> inspectToolchain(
    WorkshopBuildTarget target,
  ) async =>
      WorkshopToolchainInfo(
        target: target,
        status: WorkshopToolchainStatus.available,
        executionMode: executionMode,
        name: 'test local builder',
      );

  @override
  Future<WorkshopBuildResult> build(WorkshopBuildRequest request) async {
    buildCalls += 1;
    lastRequest = request;
    final now = DateTime.now();
    return WorkshopBuildResult(
      requestId: request.id,
      target: request.target,
      status: WorkshopBuildStatus.succeeded,
      startedAt: now,
      finishedAt: now,
      artifactPath: '${request.projectPath}/build/app.apk',
      exitCode: 0,
      testsPassed: true,
      analysisPassed: true,
      formatPassed: true,
    );
  }

  @override
  Future<void> cancel(String requestId) async {}
}

final class _RecordingWorkspaceGateway implements GitWorkspaceGateway {
  _RecordingWorkspaceGateway({required Map<String, String> files})
      : files = Map<String, String>.from(files);

  final Map<String, String> files;
  int writeCalls = 0;

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
  Future<String> commit(String message) async => 'test-commit-sha';

  @override
  Future<void> push() async {}

  @override
  Future<String> createPullRequest({
    required String title,
    required String body,
    required String headBranch,
    required String baseBranch,
  }) async =>
      'https://example.invalid/pull/1';
}

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
  test('nominal build success is rejected when tests explicitly failed',
      () async {
    final result = await _runWithBuildSignals(
      testsPassed: false,
      errors: const <String>[],
    );

    expect(result.status, WorkshopAutonomousProductionStatus.buildFailed);
    expect(result.succeeded, isFalse);
    expect(result.buildResult?.succeeded, isTrue);
    expect(result.buildResult?.hasArtifact, isTrue);
    expect(result.buildResult?.testsPassed, isFalse);
  });

  test('nominal build success is rejected when provider reports errors',
      () async {
    final result = await _runWithBuildSignals(
      testsPassed: true,
      errors: const <String>['verification_error'],
    );

    expect(result.status, WorkshopAutonomousProductionStatus.buildFailed);
    expect(result.succeeded, isFalse);
    expect(result.buildResult?.succeeded, isTrue);
    expect(result.buildResult?.hasArtifact, isTrue);
    expect(result.buildResult?.errors, contains('verification_error'));
  });
}

Future<WorkshopAutonomousProductionResult> _runWithBuildSignals({
  required bool testsPassed,
  required List<String> errors,
}) async {
  final workspace = _RecordingWorkspaceGateway(
    files: <String, String>{'lib/app.dart': 'old'},
  );
  final executor = WorkshopProjectExecutor(gateway: workspace);
  final build = _VerificationBuildProvider(
    testsPassed: testsPassed,
    errors: errors,
  );
  final buildLab = WorkshopBuildLab(
    providers: <WorkshopBuildProvider>[build],
  );
  final base = WorkshopProductionLifecycleBundleFactory.create(
    projectExecutor: executor,
    roleGateways: _approvedGateways(),
    buildLab: buildLab,
  );
  final bundle = WorkshopProductionLifecycleBundle(
    dashboardController: base.dashboardController,
    preflight: base.preflight,
    taskLifecycle: base.taskLifecycle,
    projectExecutor: base.projectExecutor,
    workspaceRootPath: '/tmp/workshop-verified-build-test',
  );

  return WorkshopAutonomousProductionCoordinator(
    bundle: bundle,
    policy: const WorkshopAutonomousProductionPolicy(
      allowRealWorkspaceApply: true,
    ),
  ).runNewProduction(
    title: 'Verified build gate',
    instruction: 'Apply the safe change and verify the final build.',
    target: WorkshopBuildTarget.android,
  );
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

Map<AppAiRole, WorkshopInferenceGateway> _approvedGateways() =>
    <AppAiRole, WorkshopInferenceGateway>{
      AppAiRole.workshopOrchestrator: _QueueGateway(
        <WorkshopInferenceResult>[_success('{}')],
      ),
      AppAiRole.architect: _QueueGateway(
        <WorkshopInferenceResult>[_success('{}')],
      ),
      AppAiRole.engineer: _QueueGateway(
        <WorkshopInferenceResult>[_success(_proposalJson)],
      ),
      AppAiRole.reviewer: _QueueGateway(
        <WorkshopInferenceResult>[
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
  _QueueGateway(List<WorkshopInferenceResult> results)
      : _results = List<WorkshopInferenceResult>.from(results),
        super(provider: _NoopProvider());

  final List<WorkshopInferenceResult> _results;

  WorkshopInferenceResult _next() {
    if (_results.isEmpty) {
      throw StateError('No queued Workshop inference result.');
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
      _next();

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
      _next();
}

final class _NoopProvider implements RuntimeInferenceProvider {
  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) => const Stream.empty();
}

final class _VerificationBuildProvider implements WorkshopBuildProvider {
  _VerificationBuildProvider({
    required this.testsPassed,
    required List<String> errors,
  }) : errors = List<String>.unmodifiable(errors);

  final bool testsPassed;
  final List<String> errors;

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
        name: 'verification test builder',
      );

  @override
  Future<WorkshopBuildResult> build(WorkshopBuildRequest request) async {
    final now = DateTime.now();
    return WorkshopBuildResult(
      requestId: request.id,
      target: request.target,
      status: WorkshopBuildStatus.succeeded,
      startedAt: now,
      finishedAt: now,
      artifactPath: '${request.projectPath}/build/app.apk',
      exitCode: 0,
      formatPassed: true,
      analysisPassed: true,
      testsPassed: testsPassed,
      errors: errors,
      message: 'Nominal provider success.',
    );
  }

  @override
  Future<void> cancel(String requestId) async {}
}

final class _RecordingWorkspaceGateway implements GitWorkspaceGateway {
  _RecordingWorkspaceGateway({required Map<String, String> files})
      : files = Map<String, String>.from(files);

  final Map<String, String> files;

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

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_autonomous_build_repair_coordinator.dart';
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
  test('repairable analyzer failure runs one reviewed repair and then succeeds',
      () async {
    final workspace = _RecordingWorkspaceGateway(
      files: <String, String>{'lib/app.dart': 'old'},
    );
    final build = _SequencedBuildProvider(<_BuildOutcome>[
      const _BuildOutcome.failure(
        code: 'local_analyze_failed',
        stderr: 'lib/app.dart:1: undefined_name: brokenValue',
      ),
      const _BuildOutcome.success(),
    ]);
    final gateways = _twoCycleGateways(
      firstContent: 'broken-but-reviewed',
      secondContent: 'fixed-after-build-diagnostics',
    );
    final bundle = _bundle(
      workspace: workspace,
      build: build,
      gateways: gateways,
    );

    final result = await WorkshopAutonomousBuildRepairCoordinator(
      bundle: bundle,
      productionPolicy: const WorkshopAutonomousProductionPolicy(
        allowRealWorkspaceApply: true,
      ),
    ).runNewProduction(
      title: 'Repair analyzer failure',
      instruction: 'Implement the requested feature.',
      target: WorkshopBuildTarget.android,
    );

    expect(result.succeeded, isTrue);
    expect(result.repaired, isTrue);
    expect(result.repairAttempts, 1);
    expect(result.attempts, hasLength(2));
    expect(build.buildCalls, 2);
    expect(workspace.writeCalls, 2);
    expect(workspace.files['lib/app.dart'], 'fixed-after-build-diagnostics');

    final engineer = gateways[AppAiRole.engineer]! as _QueueGateway;
    expect(engineer.prompts, hasLength(2));
    expect(engineer.prompts.last, contains('local_analyze_failed'));
    expect(engineer.prompts.last, contains('undefined_name: brokenValue'));
    expect(engineer.prompts.last, contains('untrusted diagnostic evidence'));
  });

  test('infrastructure failure is never sent to AI repair', () async {
    final workspace = _RecordingWorkspaceGateway(
      files: <String, String>{'lib/app.dart': 'old'},
    );
    final build = _SequencedBuildProvider(<_BuildOutcome>[
      const _BuildOutcome.failure(
        code: 'local_toolchain_unavailable',
        stderr: 'Flutter executable was not found.',
      ),
    ]);
    final gateways = _oneCycleGateways('implemented-once');
    final bundle = _bundle(
      workspace: workspace,
      build: build,
      gateways: gateways,
    );

    final result = await WorkshopAutonomousBuildRepairCoordinator(
      bundle: bundle,
      productionPolicy: const WorkshopAutonomousProductionPolicy(
        allowRealWorkspaceApply: true,
      ),
    ).runNewProduction(
      title: 'Missing toolchain',
      instruction: 'Implement the feature.',
      target: WorkshopBuildTarget.android,
    );

    expect(result.succeeded, isFalse);
    expect(result.repairableFailureDetected, isFalse);
    expect(result.repairAttempts, 0);
    expect(result.attempts, hasLength(1));
    expect(build.buildCalls, 1);
    expect(workspace.writeCalls, 1);

    final engineer = gateways[AppAiRole.engineer]! as _QueueGateway;
    expect(engineer.prompts, hasLength(1));
  });

  test('repair loop stops at configured attempt limit', () async {
    final workspace = _RecordingWorkspaceGateway(
      files: <String, String>{'lib/app.dart': 'old'},
    );
    final build = _SequencedBuildProvider(<_BuildOutcome>[
      const _BuildOutcome.failure(
        code: 'local_test_failed',
        stderr: 'Expected true, actual false.',
      ),
      const _BuildOutcome.failure(
        code: 'local_test_failed',
        stderr: 'Expected 2, actual 1.',
      ),
    ]);
    final gateways = _twoCycleGateways(
      firstContent: 'first-implementation',
      secondContent: 'first-repair',
    );
    final bundle = _bundle(
      workspace: workspace,
      build: build,
      gateways: gateways,
    );

    final result = await WorkshopAutonomousBuildRepairCoordinator(
      bundle: bundle,
      productionPolicy: const WorkshopAutonomousProductionPolicy(
        allowRealWorkspaceApply: true,
      ),
      repairPolicy: const WorkshopAutonomousBuildRepairPolicy(
        maxRepairAttempts: 1,
      ),
    ).runNewProduction(
      title: 'Bounded repair',
      instruction: 'Implement the feature and keep tests passing.',
      target: WorkshopBuildTarget.android,
    );

    expect(result.succeeded, isFalse);
    expect(result.repairableFailureDetected, isTrue);
    expect(result.repairAttempts, 1);
    expect(result.attempts, hasLength(2));
    expect(
      result.finalResult.status,
      WorkshopAutonomousProductionStatus.buildFailed,
    );
    expect(build.buildCalls, 2);
    expect(workspace.writeCalls, 2);
  });

  test('offline repair keeps inference and every build offline-local', () async {
    final workspace = _RecordingWorkspaceGateway(
      files: <String, String>{'lib/app.dart': 'old'},
    );
    final build = _SequencedBuildProvider(<_BuildOutcome>[
      const _BuildOutcome.failure(
        code: 'local_build_failed',
        stderr: 'Compilation failed in lib/app.dart.',
      ),
      const _BuildOutcome.success(),
    ]);
    final gateways = _twoCycleGateways(
      firstContent: 'offline-broken',
      secondContent: 'offline-fixed',
    );
    final bundle = _bundle(
      workspace: workspace,
      build: build,
      gateways: gateways,
    );

    final result = await WorkshopAutonomousBuildRepairCoordinator(
      bundle: bundle,
      productionPolicy: const WorkshopAutonomousProductionPolicy(
        allowRealWorkspaceApply: true,
      ),
    ).runNewProduction(
      title: 'Offline repair',
      instruction: 'Build this project with no network.',
      target: WorkshopBuildTarget.android,
      isOffline: true,
      buildMode: WorkshopBuildExecutionMode.remote,
    );

    expect(result.succeeded, isTrue);
    expect(result.repaired, isTrue);
    expect(
      build.requests.map((request) => request.mode),
      everyElement(WorkshopBuildExecutionMode.offlineLocal),
    );
    for (final gateway in gateways.values.whereType<_QueueGateway>()) {
      expect(gateway.offlineFlags, isNotEmpty);
      expect(gateway.offlineFlags, everyElement(isTrue));
    }
  });
}

WorkshopProductionLifecycleBundle _bundle({
  required _RecordingWorkspaceGateway workspace,
  required _SequencedBuildProvider build,
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
    workspaceRootPath: '/tmp/workshop-autonomous-repair-project',
  );
}

Map<AppAiRole, WorkshopInferenceGateway> _oneCycleGateways(String content) =>
    <AppAiRole, WorkshopInferenceGateway>{
      AppAiRole.workshopOrchestrator: _QueueGateway(
        results: <WorkshopInferenceResult>[_success('{}')],
      ),
      AppAiRole.architect: _QueueGateway(
        results: <WorkshopInferenceResult>[_success('{}')],
      ),
      AppAiRole.engineer: _QueueGateway(
        results: <WorkshopInferenceResult>[_success(_proposal(content))],
      ),
      AppAiRole.reviewer: _QueueGateway(
        results: <WorkshopInferenceResult>[
          _success(_approvedReviewJson),
          _success(_validValidationJson),
        ],
      ),
    };

Map<AppAiRole, WorkshopInferenceGateway> _twoCycleGateways({
  required String firstContent,
  required String secondContent,
}) =>
    <AppAiRole, WorkshopInferenceGateway>{
      AppAiRole.workshopOrchestrator: _QueueGateway(
        results: <WorkshopInferenceResult>[
          _success('{}'),
          _success('{}'),
        ],
      ),
      AppAiRole.architect: _QueueGateway(
        results: <WorkshopInferenceResult>[
          _success('{}'),
          _success('{}'),
        ],
      ),
      AppAiRole.engineer: _QueueGateway(
        results: <WorkshopInferenceResult>[
          _success(_proposal(firstContent)),
          _success(_proposal(secondContent)),
        ],
      ),
      AppAiRole.reviewer: _QueueGateway(
        results: <WorkshopInferenceResult>[
          _success(_approvedReviewJson),
          _success(_validValidationJson),
          _success(_approvedReviewJson),
          _success(_validValidationJson),
        ],
      ),
    };

String _proposal(String content) =>
    '{"summary":"Update app","explanation":"Implement safe change",'
    '"changes":[{"path":"lib/app.dart","type":"modification",'
    '"content":"$content"}],"validationNotes":[],"warnings":[]}';

const String _approvedReviewJson =
    '{"approved":true,"summary":"Review passed","findings":[],"warnings":[]}';
const String _validValidationJson =
    '{"valid":true,"summary":"Validation passed","checks":["consistent"],'
    '"warnings":[]}';

WorkshopInferenceResult _success(String text) => WorkshopInferenceResult(
      text: text,
      terminalState: InferenceTerminalState.success,
    );

final class _QueueGateway extends WorkshopInferenceGateway {
  _QueueGateway({required List<WorkshopInferenceResult> results})
      : _results = List<WorkshopInferenceResult>.from(results),
        super(provider: _NoopProvider());

  final List<WorkshopInferenceResult> _results;
  final List<String> prompts = <String>[];
  final List<bool> offlineFlags = <bool>[];

  WorkshopInferenceResult _next(String prompt, bool isOffline) {
    prompts.add(prompt);
    offlineFlags.add(isOffline);
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
      _next(prompt, isOffline);

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
      _next(prompt, isOffline);
}

final class _NoopProvider implements RuntimeInferenceProvider {
  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) => const Stream.empty();
}

final class _BuildOutcome {
  const _BuildOutcome.success()
      : succeeded = true,
        code = null,
        stderr = '';

  const _BuildOutcome.failure({
    required this.code,
    required this.stderr,
  }) : succeeded = false;

  final bool succeeded;
  final String? code;
  final String stderr;
}

final class _SequencedBuildProvider implements WorkshopBuildProvider {
  _SequencedBuildProvider(List<_BuildOutcome> outcomes)
      : _outcomes = List<_BuildOutcome>.from(outcomes);

  final List<_BuildOutcome> _outcomes;
  final List<WorkshopBuildRequest> requests = <WorkshopBuildRequest>[];

  int get buildCalls => requests.length;

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
        name: 'sequenced test builder',
      );

  @override
  Future<WorkshopBuildResult> build(WorkshopBuildRequest request) async {
    requests.add(request);
    if (_outcomes.isEmpty) {
      throw StateError('No queued build outcome.');
    }

    final outcome = _outcomes.removeAt(0);
    final now = DateTime.now();

    if (outcome.succeeded) {
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
        testsPassed: true,
        message: 'Build succeeded.',
      );
    }

    return WorkshopBuildResult(
      requestId: request.id,
      target: request.target,
      status: WorkshopBuildStatus.failed,
      startedAt: now,
      finishedAt: now,
      exitCode: 1,
      formatPassed: outcome.code != 'local_format_failed',
      analysisPassed: outcome.code != 'local_analyze_failed',
      testsPassed: outcome.code != 'local_test_failed',
      stderr: outcome.stderr,
      errors: <String>[outcome.code!],
      message: 'Build failed with ${outcome.code}.',
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

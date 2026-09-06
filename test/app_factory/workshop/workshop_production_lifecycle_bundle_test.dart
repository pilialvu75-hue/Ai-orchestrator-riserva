import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_apply_approval_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_lifecycle_bundle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

void main() {
  test(
    'production bundle reuses dashboard session through approval and apply',
    () async {
      final workspaceGateway = _RecordingWorkspaceGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final executor = WorkshopProjectExecutor(
        gateway: workspaceGateway,
      );
      final callOrder = <AppAiRole>[];
      final bundle = WorkshopProductionLifecycleBundleFactory.create(
        projectExecutor: executor,
        roleGateways: _gateways(callOrder),
      );

      final plan = bundle.dashboardController.startProduction(
        title: 'Production bundle',
        instruction: 'Update the application safely.',
      );
      final preparedSession =
          await bundle.dashboardController.prepareNextTask();
      final activeTaskId = bundle.dashboardController.state.activeTaskId;

      final WorkspaceSession session = preparedSession ??
          (throw StateError('Dashboard did not prepare a task session.'));
      final String taskId = activeTaskId ??
          (throw StateError('Dashboard did not expose an active task id.'));

      expect(taskId, 'task:initial-implementation');
      expect(identical(executor.sessionForTask(taskId), session), isTrue);

      final inference = await bundle.taskLifecycle.runPrepared(
        taskId: taskId,
      );

      expect(inference.readyForApproval, isTrue);
      expect(session.status, WorkspaceSessionStatus.validation);
      expect(session.workspace.read('lib/app.dart'), 'new');
      expect(workspaceGateway.files['lib/app.dart'], 'old');
      expect(workspaceGateway.writeCalls, 0);
      expect(
        callOrder,
        <AppAiRole>[
          AppAiRole.engineer,
          AppAiRole.reviewer,
          AppAiRole.reviewer,
        ],
      );

      bundle.taskLifecycle.decide(
        taskId: taskId,
        decision: WorkshopApplyDecision.approve,
      );

      expect(session.status, WorkspaceSessionStatus.approved);
      expect(workspaceGateway.writeCalls, 0);

      final applied = await bundle.taskLifecycle.applyApprovedAndComplete(
        plan: plan,
        taskId: taskId,
      );

      expect(identical(applied, session), isTrue);
      expect(session.status, WorkspaceSessionStatus.completed);
      expect(workspaceGateway.files['lib/app.dart'], 'new');
      expect(workspaceGateway.writeCalls, 1);
      expect(
        plan.status,
        WorkshopProjectStatus.completed,
      );
      expect(workspaceGateway.commitCalls, 0);
      expect(workspaceGateway.pushCalls, 0);
      expect(workspaceGateway.pullRequestCalls, 0);
    },
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

Map<AppAiRole, WorkshopInferenceGateway> _gateways(
  List<AppAiRole> callOrder,
) =>
    <AppAiRole, WorkshopInferenceGateway>{
      AppAiRole.workshopOrchestrator: _QueueGateway(
        role: AppAiRole.workshopOrchestrator,
        callOrder: callOrder,
        results: <WorkshopInferenceResult>[_success('{}')],
      ),
      AppAiRole.architect: _QueueGateway(
        role: AppAiRole.architect,
        callOrder: callOrder,
        results: <WorkshopInferenceResult>[_success('{}')],
      ),
      AppAiRole.engineer: _QueueGateway(
        role: AppAiRole.engineer,
        callOrder: callOrder,
        results: <WorkshopInferenceResult>[_success(_proposalJson)],
      ),
      AppAiRole.reviewer: _QueueGateway(
        role: AppAiRole.reviewer,
        callOrder: callOrder,
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
    required this.callOrder,
    required List<WorkshopInferenceResult> results,
  })  : _results = List<WorkshopInferenceResult>.from(results),
        super(provider: _NoopProvider());

  final AppAiRole role;
  final List<AppAiRole> callOrder;
  final List<WorkshopInferenceResult> _results;

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
    callOrder.add(role);
    if (_results.isEmpty) {
      throw StateError('No queued result for ${role.id}.');
    }
    return _results.removeAt(0);
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
    deleteCalls += 1;
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

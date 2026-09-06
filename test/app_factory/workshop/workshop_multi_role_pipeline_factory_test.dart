import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_multi_role_pipeline_factory.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

void main() {
  group('WorkshopMultiRolePipelineFactory', () {
    test('requires exactly the four Workshop roles and rejects Assistant', () {
      final callOrder = <AppAiRole>[];
      final gateways = _gateways(callOrder);

      final router = WorkshopMultiRolePipelineFactory.createRouter(
        gateways: gateways,
      );

      expect(
        router.roles,
        <AppAiRole>{
          AppAiRole.workshopOrchestrator,
          AppAiRole.architect,
          AppAiRole.engineer,
          AppAiRole.reviewer,
        },
      );
      expect(
        () => router.gatewayFor(AppAiRole.assistantOrchestrator),
        throwsStateError,
      );

      expect(
        () => WorkshopMultiRolePipelineFactory.createRouter(
          gateways: <AppAiRole, WorkshopInferenceGateway>{
            ...gateways,
            AppAiRole.assistantOrchestrator: _QueueGateway(
              role: AppAiRole.assistantOrchestrator,
              callOrder: callOrder,
              results: <WorkshopInferenceResult>[_success('{}')],
            ),
          },
        ),
        throwsArgumentError,
      );
    });

    test('composes Engineer -> Reviewer -> Reviewer for a prepared task',
        () async {
      final realGateway = _RecordingWorkspaceGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final executor = WorkshopProjectExecutor(gateway: realGateway);
      final session = await executor.prepareTask(
        _plan(),
        'task:implementation',
      );
      final callOrder = <AppAiRole>[];

      final runner = WorkshopMultiRolePipelineFactory.createPreparedTaskRunner(
        executor: executor,
        gateways: _gateways(callOrder),
      );

      final result = await runner.run(taskId: 'task:implementation');

      expect(result.readyForApproval, isTrue);
      expect(session.status, WorkspaceSessionStatus.validation);
      expect(session.isApplyApproved, isFalse);
      expect(session.workspace.read('lib/app.dart'), 'new');
      expect(
        callOrder,
        <AppAiRole>[
          AppAiRole.engineer,
          AppAiRole.reviewer,
          AppAiRole.reviewer,
        ],
      );
      expect(realGateway.files['lib/app.dart'], 'old');
      expect(realGateway.writeCalls, 0);
      expect(realGateway.deleteCalls, 0);
      expect(realGateway.commitCalls, 0);
      expect(realGateway.pushCalls, 0);
      expect(realGateway.pullRequestCalls, 0);
    });
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

WorkshopProjectPlan _plan() {
  return WorkshopProjectPlan(
    id: 'project:multi-role-factory',
    title: 'Multi-role project',
    goal: 'Update the app safely',
    status: WorkshopProjectStatus.planned,
    phases: <WorkshopProjectPhase>[
      WorkshopProjectPhase(
        id: 'phase:implementation',
        title: 'Implementation',
        description: 'Implement the requested change',
        taskIds: const <String>['task:implementation'],
      ),
    ],
    tasks: <WorkshopProjectTask>[
      WorkshopProjectTask(
        id: 'task:implementation',
        title: 'Update app',
        description: 'Update the app safely',
        phaseId: 'phase:implementation',
        affectedPaths: const <String>['lib/app.dart'],
        validationCriteria: const <String>['No regressions'],
      ),
    ],
  );
}

Map<AppAiRole, WorkshopInferenceGateway> _gateways(
  List<AppAiRole> callOrder,
) {
  return <AppAiRole, WorkshopInferenceGateway>{
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
}

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
  }) {
    return const Stream.empty();
  }
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

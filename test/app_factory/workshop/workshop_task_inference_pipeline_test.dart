import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_router.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

void main() {
  group('WorkshopTaskInferencePipeline', () {
    test('runs Engineer then Reviewer review and validation without real writes',
        () async {
      final callOrder = <AppAiRole>[];
      final engineer = _QueueGateway(
        role: AppAiRole.engineer,
        callOrder: callOrder,
        results: <WorkshopInferenceResult>[
          _success(_proposalJson),
        ],
      );
      final reviewer = _QueueGateway(
        role: AppAiRole.reviewer,
        callOrder: callOrder,
        results: <WorkshopInferenceResult>[
          _success(_approvedReviewJson),
          _success(_validValidationJson),
        ],
      );
      final gateways = _gateways(
        engineer: engineer,
        reviewer: reviewer,
        callOrder: callOrder,
      );
      final realGateway = _RecordingWorkspaceGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final session = await _session(realGateway);

      final result = await WorkshopTaskInferencePipeline(
        inference: _stageInference(gateways),
      ).run(session: session);

      expect(result.readyForApproval, isTrue);
      expect(result.review.approved, isTrue);
      expect(result.validation?.valid, isTrue);
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
      expect(gateways[AppAiRole.workshopOrchestrator]!.calls, 0);
      expect(gateways[AppAiRole.architect]!.calls, 0);
      expect(realGateway.writeCalls, 0);
      expect(realGateway.deleteCalls, 0);
      expect(realGateway.commitCalls, 0);
      expect(realGateway.pushCalls, 0);
      expect(realGateway.pullRequestCalls, 0);
    });

    test('Reviewer rejection blocks before validation and never writes',
        () async {
      final callOrder = <AppAiRole>[];
      final engineer = _QueueGateway(
        role: AppAiRole.engineer,
        callOrder: callOrder,
        results: <WorkshopInferenceResult>[
          _success(_proposalJson),
        ],
      );
      final reviewer = _QueueGateway(
        role: AppAiRole.reviewer,
        callOrder: callOrder,
        results: <WorkshopInferenceResult>[
          _success(_rejectedReviewJson),
          _success(_validValidationJson),
        ],
      );
      final realGateway = _RecordingWorkspaceGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final session = await _session(realGateway);

      final result = await WorkshopTaskInferencePipeline(
        inference: _stageInference(
          _gateways(
            engineer: engineer,
            reviewer: reviewer,
            callOrder: callOrder,
          ),
        ),
      ).run(session: session);

      expect(result.readyForApproval, isFalse);
      expect(result.review.approved, isFalse);
      expect(result.validation, isNull);
      expect(session.status, WorkspaceSessionStatus.blocked);
      expect(reviewer.calls, 1);
      expect(
        callOrder,
        <AppAiRole>[AppAiRole.engineer, AppAiRole.reviewer],
      );
      expect(realGateway.writeCalls, 0);
      expect(realGateway.deleteCalls, 0);
    });

    test('failed validation blocks and never approves or applies', () async {
      final callOrder = <AppAiRole>[];
      final engineer = _QueueGateway(
        role: AppAiRole.engineer,
        callOrder: callOrder,
        results: <WorkshopInferenceResult>[
          _success(_proposalJson),
        ],
      );
      final reviewer = _QueueGateway(
        role: AppAiRole.reviewer,
        callOrder: callOrder,
        results: <WorkshopInferenceResult>[
          _success(_approvedReviewJson),
          _success(_invalidValidationJson),
        ],
      );
      final realGateway = _RecordingWorkspaceGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final session = await _session(realGateway);

      final result = await WorkshopTaskInferencePipeline(
        inference: _stageInference(
          _gateways(
            engineer: engineer,
            reviewer: reviewer,
            callOrder: callOrder,
          ),
        ),
      ).run(session: session);

      expect(result.readyForApproval, isFalse);
      expect(result.review.approved, isTrue);
      expect(result.validation?.valid, isFalse);
      expect(session.status, WorkspaceSessionStatus.blocked);
      expect(session.isApplyApproved, isFalse);
      expect(reviewer.calls, 2);
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

const String _rejectedReviewJson =
    '{"approved":false,"summary":"Review rejected","findings":["regression"],'
    '"warnings":[]}';

const String _validValidationJson =
    '{"valid":true,"summary":"Validation passed","checks":["consistent"],'
    '"warnings":[]}';

const String _invalidValidationJson =
    '{"valid":false,"summary":"Validation failed","checks":["unsafe"],'
    '"warnings":[]}';

WorkshopInferenceResult _success(String text) => WorkshopInferenceResult(
      text: text,
      terminalState: InferenceTerminalState.success,
    );

WorkshopStageRoleInference _stageInference(
  Map<AppAiRole, _QueueGateway> gateways,
) {
  return WorkshopStageRoleInference(
    executor: WorkshopRoleInferenceExecutor(
      router: WorkshopRoleInferenceRouter(gateways: gateways),
    ),
  );
}

Map<AppAiRole, _QueueGateway> _gateways({
  required _QueueGateway engineer,
  required _QueueGateway reviewer,
  required List<AppAiRole> callOrder,
}) {
  final idle = <WorkshopInferenceResult>[_success('{}')];

  return <AppAiRole, _QueueGateway>{
    AppAiRole.workshopOrchestrator: _QueueGateway(
      role: AppAiRole.workshopOrchestrator,
      callOrder: callOrder,
      results: List<WorkshopInferenceResult>.from(idle),
    ),
    AppAiRole.architect: _QueueGateway(
      role: AppAiRole.architect,
      callOrder: callOrder,
      results: List<WorkshopInferenceResult>.from(idle),
    ),
    AppAiRole.engineer: engineer,
    AppAiRole.reviewer: reviewer,
  };
}

Future<WorkspaceSession> _session(_RecordingWorkspaceGateway gateway) async {
  final session = WorkspaceSession(
    request: const WorkshopRequest(
      id: 'pipeline-request',
      title: 'Implement task',
      instruction: 'Update the app safely',
      targetFiles: <String>['lib/app.dart'],
      constraints: <String>['No regressions'],
    ),
    gateway: gateway,
  );

  await session.initialize();
  return session;
}

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
  int calls = 0;

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

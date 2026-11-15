import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_resume_context.dart';
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
  test('semantic retry resumes review without re-entering Engineer', () async {
    final engineer = _QueueGateway(<WorkshopInferenceResult>[
      _success(
        '{"changes":[{"path":"lib/main.dart","type":"modification","content":"unexpected"}]}',
      ),
    ]);
    final reviewer = _QueueGateway(<WorkshopInferenceResult>[
      _success(
        '{"approved":true,"summary":"Review passed","findings":[],"warnings":[]}',
      ),
      _success(
        '{"valid":true,"summary":"Validation passed","checks":["ok"],"warnings":[]}',
      ),
    ]);
    final session = await _session();
    session.workspace.write(
      path: 'lib/main.dart',
      content: 'void main() { print("staged"); }',
    );
    session.beginReview();

    final stages = <WorkshopStage>[];
    final result = await WorkshopTaskInferencePipeline(
      inference: _stageInference(engineer: engineer, reviewer: reviewer),
    ).runWithResumeContext(
      session: session,
      resumeContext: _resume(phase: 'failed'),
      onStage: stages.add,
    );

    expect(engineer.calls, 0);
    expect(reviewer.calls, 2);
    expect(
      stages,
      <WorkshopStage>[WorkshopStage.review, WorkshopStage.validation],
    );
    expect(result.proposal.changes, hasLength(1));
    expect(result.proposal.changes.single.path, 'lib/main.dart');
    expect(result.review.approved, isTrue);
    expect(result.validation?.valid, isTrue);
    expect(result.readyForApproval, isTrue);
    expect(session.status, WorkspaceSessionStatus.validation);
    expect(
      session.workspace.read('lib/main.dart'),
      'void main() { print("staged"); }',
    );
  });

  test('semantic retry resumes validation without rerunning review or Engineer',
      () async {
    final engineer = _QueueGateway(<WorkshopInferenceResult>[
      _success('{}'),
    ]);
    final reviewer = _QueueGateway(<WorkshopInferenceResult>[
      _success(
        '{"valid":true,"summary":"Validation recovered","checks":["ok"],"warnings":[]}',
      ),
    ]);
    final session = await _session();
    session.workspace.write(path: 'lib/main.dart', content: 'new');
    session.beginReview();
    session.beginValidation();

    final stages = <WorkshopStage>[];
    final result = await WorkshopTaskInferencePipeline(
      inference: _stageInference(engineer: engineer, reviewer: reviewer),
    ).runWithResumeContext(
      session: session,
      resumeContext: _resume(phase: 'validation'),
      onStage: stages.add,
    );

    expect(engineer.calls, 0);
    expect(reviewer.calls, 1);
    expect(stages, <WorkshopStage>[WorkshopStage.validation]);
    expect(result.review.approved, isTrue);
    expect(result.validation?.valid, isTrue);
    expect(result.readyForApproval, isTrue);
    expect(session.status, WorkspaceSessionStatus.validation);
  });
}

WorkshopInferenceResult _success(String text) => WorkshopInferenceResult(
      text: text,
      terminalState: InferenceTerminalState.success,
    );

WorkshopResumeContext _resume({required String phase}) => WorkshopResumeContext(
      executionId: 'execution-1',
      attemptId: 'attempt-2',
      projectId: 'project-1',
      taskId: 'task-1',
      sessionId: 'production:project-1:task-1',
      objective: 'Repair Manga Kids',
      phase: phase,
    );

WorkshopStageRoleInference _stageInference({
  required _QueueGateway engineer,
  required _QueueGateway reviewer,
}) {
  final idle = _QueueGateway(<WorkshopInferenceResult>[_success('{}')]);
  return WorkshopStageRoleInference(
    executor: WorkshopRoleInferenceExecutor(
      router: WorkshopRoleInferenceRouter(
        gateways: <AppAiRole, WorkshopInferenceGateway>{
          AppAiRole.workshopOrchestrator: idle,
          AppAiRole.architect: _QueueGateway(
            <WorkshopInferenceResult>[_success('{}')],
          ),
          AppAiRole.engineer: engineer,
          AppAiRole.reviewer: reviewer,
        },
      ),
    ),
  );
}

Future<WorkspaceSession> _session() async {
  final session = WorkspaceSession(
    request: const WorkshopRequest(
      id: 'manga-kids-repair',
      title: 'Manga Kids — build repair 1',
      instruction: 'Repair the staged app safely.',
      operation: WorkshopOperation.modify,
      targetFiles: <String>['lib/main.dart'],
    ),
    gateway: _MemoryGateway(
      <String, String>{'lib/main.dart': 'void main() {}'},
    ),
  );
  await session.initialize();
  return session;
}

final class _QueueGateway extends WorkshopInferenceGateway {
  _QueueGateway(List<WorkshopInferenceResult> results)
      : _results = List<WorkshopInferenceResult>.from(results),
        super(provider: _NoopProvider());

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
    if (_results.isEmpty) {
      throw StateError('Unexpected inference call.');
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

final class _MemoryGateway implements GitWorkspaceGateway {
  _MemoryGateway(Map<String, String> files)
      : _files = Map<String, String>.from(files);

  final Map<String, String> _files;

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

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
  test('create task recovers after two empty Engineer proposals', () async {
    final callOrder = <AppAiRole>[];
    final engineer = _QueueGateway(
      role: AppAiRole.engineer,
      callOrder: callOrder,
      results: <WorkshopInferenceResult>[
        _success('{"explanation":"planning only","changes":[]}'),
        _success('{"explanation":"still planning","changes":[]}'),
        _success(
          '{"explanation":"Materialize Manga Bigs",'
          '"changes":[{"path":"lib/main.dart","type":"modification",'
          '"content":"void main() {}"}]}',
        ),
      ],
    );
    final reviewer = _QueueGateway(
      role: AppAiRole.reviewer,
      callOrder: callOrder,
      results: <WorkshopInferenceResult>[
        _success(
          '{"approved":true,"summary":"Review passed","findings":[],"warnings":[]}',
        ),
        _success(
          '{"valid":true,"summary":"Validation passed","checks":["consistent"],"warnings":[]}',
        ),
      ],
    );
    final gateway = _RecordingWorkspaceGateway(
      files: <String, String>{'lib/main.dart': 'void main() { }'},
    );
    final session = WorkspaceSession(
      request: const WorkshopRequest(
        id: 'manga-bigs-empty-create',
        title: 'Manga Bigs',
        instruction:
            'Create Manga Bigs with categories, detail pages and favorites.',
        operation: WorkshopOperation.create,
        targetFiles: <String>['lib/main.dart'],
        constraints: <String>['Flutter standard components only'],
      ),
      gateway: gateway,
    );
    await session.initialize();

    final pipeline = WorkshopTaskInferencePipeline(
      inference: _stageInference(
        _gateways(
          engineer: engineer,
          reviewer: reviewer,
          callOrder: callOrder,
        ),
      ),
    );

    final result = await pipeline.run(session: session);

    expect(result.readyForApproval, isTrue);
    expect(engineer.calls, 3);
    expect(reviewer.calls, 2);
    expect(session.workspace.read('lib/main.dart'), 'void main() {}');
    expect(
      engineer.prompts.last,
      contains('already failed CREATE materialization'),
    );
    expect(engineer.prompts.last, contains('Manga Bigs'));
    expect(engineer.prompts.last, contains('lib/main.dart'));
    expect(gateway.writeCalls, 0);
    expect(gateway.commitCalls, 0);
    expect(gateway.pushCalls, 0);
  });

  test('create task recovers when repaired proposal omits required main.dart',
      () async {
    final callOrder = <AppAiRole>[];
    final engineer = _QueueGateway(
      role: AppAiRole.engineer,
      callOrder: callOrder,
      results: <WorkshopInferenceResult>[
        _success(
          '{"explanation":"Add catalog only",'
          '"changes":[{"path":"lib/catalog.dart","type":"addition",'
          '"content":"const catalog = <String>[];"}]}',
        ),
        _success(
          '{"explanation":"Still catalog only",'
          '"changes":[{"path":"lib/catalog.dart","type":"addition",'
          '"content":"const catalog = <String>[];"}]}',
        ),
        _success(
          '{"explanation":"Materialize required entry point",'
          '"changes":[{"path":"lib/main.dart","type":"addition",'
          '"content":"void main() {}"}]}',
        ),
      ],
    );
    final reviewer = _QueueGateway(
      role: AppAiRole.reviewer,
      callOrder: callOrder,
      results: <WorkshopInferenceResult>[
        _success(
          '{"approved":true,"summary":"Review passed","findings":[],"warnings":[]}',
        ),
        _success(
          '{"valid":true,"summary":"Validation passed","checks":["consistent"],"warnings":[]}',
        ),
      ],
    );
    final gateway = _RecordingWorkspaceGateway(files: <String, String>{});
    final session = WorkspaceSession(
      request: const WorkshopRequest(
        id: 'manga-bigs-required-main',
        title: 'Manga Bigs',
        instruction:
            'Create Manga Bigs with categories, detail pages and favorites.',
        operation: WorkshopOperation.create,
        targetFiles: <String>['lib/main.dart', 'lib/catalog.dart'],
        constraints: <String>['Flutter standard components only'],
      ),
      gateway: gateway,
    );
    await session.initialize();

    final pipeline = WorkshopTaskInferencePipeline(
      inference: _stageInference(
        _gateways(
          engineer: engineer,
          reviewer: reviewer,
          callOrder: callOrder,
        ),
      ),
    );

    final result = await pipeline.run(session: session);

    expect(result.readyForApproval, isTrue);
    expect(engineer.calls, 3);
    expect(reviewer.calls, 2);
    expect(session.workspace.read('lib/main.dart'), 'void main() {}');
    expect(session.workspace.contains('lib/catalog.dart'), isFalse);
    expect(
      engineer.prompts.last,
      contains('already failed CREATE materialization'),
    );
    expect(
      engineer.prompts.last,
      contains('MUST include one complete non-deletion change'),
    );
    expect(engineer.prompts.last, contains('lib/main.dart'));
    expect(gateway.writeCalls, 0);
    expect(gateway.commitCalls, 0);
    expect(gateway.pushCalls, 0);
  });
}

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
  return <AppAiRole, _QueueGateway>{
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
    AppAiRole.engineer: engineer,
    AppAiRole.reviewer: reviewer,
  };
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
  final List<String> prompts = <String>[];
  int calls = 0;

  @override
  Future<WorkshopInferenceResult> completeWithFirstTokenTimeout({
    required String prompt,
    required Duration firstTokenTimeout,
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
  }) =>
      complete(
        prompt: prompt,
        systemPrompt: systemPrompt,
        context: context,
        sessionId: sessionId,
        isOffline: isOffline,
        maxTokens: maxTokens,
        temperature: temperature,
        topP: topP,
        repeatPenalty: repeatPenalty,
        modelId: modelId,
        modelPath: modelPath,
        cancellationToken: cancellationToken,
      );

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
    prompts.add(prompt);
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
  Future<void> writeFile({
    required String path,
    required String content,
  }) async {
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

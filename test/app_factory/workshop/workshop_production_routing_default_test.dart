import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_lifecycle_bundle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_task_handle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_executor.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

void main() {
  test('production model chain follows runtime routing by default', () async {
    final workspace = _MemoryWorkspaceGateway();
    final executor = WorkshopProjectExecutor(gateway: workspace);

    final orchestrator = _CapturingGateway(<WorkshopInferenceResult>[
      _success('{}'),
    ]);
    final architect = _CapturingGateway(<WorkshopInferenceResult>[
      _success('{}'),
    ]);
    final engineer = _CapturingGateway(<WorkshopInferenceResult>[
      _success(_proposalJson),
    ]);
    final reviewer = _CapturingGateway(<WorkshopInferenceResult>[
      _success(_reviewJson),
      _success(_validationJson),
    ]);

    final bundle = WorkshopProductionLifecycleBundleFactory.create(
      projectExecutor: executor,
      roleGateways: <AppAiRole, WorkshopInferenceGateway>{
        AppAiRole.workshopOrchestrator: orchestrator,
        AppAiRole.architect: architect,
        AppAiRole.engineer: engineer,
        AppAiRole.reviewer: reviewer,
      },
    );
    final coordinator = WorkshopProductionTaskCoordinator(bundle: bundle);

    final handle = await coordinator.startAndPrepare(
      title: 'Routing test',
      instruction: 'Update the app safely.',
    );

    final result = await coordinator.runPrepared(handle: handle);

    expect(result.readyForApproval, isTrue);
    expect(orchestrator.offlineValues, everyElement(isFalse));
    expect(architect.offlineValues, everyElement(isFalse));
    expect(engineer.offlineValues, everyElement(isFalse));
    expect(reviewer.offlineValues, everyElement(isFalse));
  });
}

const String _proposalJson =
    '{"summary":"Update app","explanation":"Implement requested change",'
    '"changes":[{"path":"lib/app.dart","type":"modification",'
    '"content":"new"}],"validationNotes":[],"warnings":[]}';
const String _reviewJson =
    '{"approved":true,"summary":"Review passed","findings":[],"warnings":[]}';
const String _validationJson =
    '{"valid":true,"summary":"Validation passed","checks":["consistent"],'
    '"warnings":[]}';

WorkshopInferenceResult _success(String text) => WorkshopInferenceResult(
      text: text,
      terminalState: InferenceTerminalState.success,
    );

final class _CapturingGateway extends WorkshopInferenceGateway {
  _CapturingGateway(List<WorkshopInferenceResult> results)
      : _results = List<WorkshopInferenceResult>.from(results),
        super(provider: _NoopProvider());

  final List<WorkshopInferenceResult> _results;
  final List<bool> offlineValues = <bool>[];

  WorkshopInferenceResult _next(bool isOffline) {
    offlineValues.add(isOffline);
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
    bool isOffline = true,
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
  }) async =>
      _next(isOffline);
}

final class _NoopProvider implements RuntimeInferenceProvider {
  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) =>
      const Stream<InferenceResponse>.empty();
}

final class _MemoryWorkspaceGateway implements GitWorkspaceGateway {
  final Map<String, String> files = <String, String>{
    'lib/app.dart': 'old',
  };

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
  Future<String> commit(String message) async => 'test-commit';

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

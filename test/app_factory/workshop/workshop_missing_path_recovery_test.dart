import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_implementation_runner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_router.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

void main() {
  test('Engineer change missing path is retried structurally and recovered',
      () async {
    const path = 'lib/screens/favorites_screen.dart';
    final engineer = _StaticGateway(
      results: const <WorkshopInferenceResult>[
        WorkshopInferenceResult(
          text:
              '{"explanation":"missing path","changes":[{"type":"addition","content":"class FavoritesScreen {}"}]}',
          terminalState: InferenceTerminalState.success,
          model: 'qwen2_5_3b_instruct',
        ),
        WorkshopInferenceResult(
          text:
              '{"explanation":"Recovered missing path","changes":[{"path":"lib/screens/favorites_screen.dart","type":"addition","content":"class FavoritesScreen { const FavoritesScreen(); }"}]}',
          terminalState: InferenceTerminalState.success,
          model: 'qwen2_5_3b_instruct',
        ),
      ],
    );
    final gateway = _RecordingWorkspaceGateway(files: const <String, String>{});
    final session = WorkspaceSession(
      request: const WorkshopRequest(
        id: 'missing-path-recovery',
        title: 'Create favorites screen',
        instruction: 'Create the favorites screen exactly once.',
        operation: WorkshopOperation.create,
        targetFiles: <String>[path],
      ),
      gateway: gateway,
    );
    await session.initialize();

    final proposal = await WorkshopProposalImplementationRunner(
      inference: _stageInference(_gateways(engineer)),
    ).run(session: session);

    expect(proposal.changes, hasLength(1));
    expect(proposal.changes.single.path, path);
    expect(proposal.explanation, 'Recovered missing path');
    expect(engineer.calls, 2);
    expect(engineer.maxTokensValues, <int?>[640, 768]);

    final compactPayload = jsonDecode(
      engineer.prompts.last.split('\n')[1],
    ) as Map<String, dynamic>;
    expect(
      compactPayload['gateFeedback'],
      'Previous Engineer proposal was rejected before review: '
      'Workshop proposal field "path" is required.',
    );

    expect(
      session.workspace.read(path),
      'class FavoritesScreen { const FavoritesScreen(); }',
    );
    expect(session.status, WorkspaceSessionStatus.review);
    expect(session.isApplyApproved, isFalse);
    expect(gateway.writeCalls, 0);
    expect(gateway.deleteCalls, 0);
    expect(gateway.commitCalls, 0);
    expect(gateway.pushCalls, 0);
    expect(gateway.pullRequestCalls, 0);
  });
}

WorkshopStageRoleInference _stageInference(
  Map<AppAiRole, _StaticGateway> gateways,
) {
  return WorkshopStageRoleInference(
    executor: WorkshopRoleInferenceExecutor(
      router: WorkshopRoleInferenceRouter(gateways: gateways),
    ),
  );
}

Map<AppAiRole, _StaticGateway> _gateways(_StaticGateway engineer) {
  const idle = WorkshopInferenceResult(
    text: '{}',
    terminalState: InferenceTerminalState.success,
  );
  return <AppAiRole, _StaticGateway>{
    AppAiRole.workshopOrchestrator:
        _StaticGateway(results: const <WorkshopInferenceResult>[idle]),
    AppAiRole.architect:
        _StaticGateway(results: const <WorkshopInferenceResult>[idle]),
    AppAiRole.engineer: engineer,
    AppAiRole.reviewer:
        _StaticGateway(results: const <WorkshopInferenceResult>[idle]),
  };
}

final class _StaticGateway extends WorkshopInferenceGateway {
  _StaticGateway({required List<WorkshopInferenceResult> results})
      : _results = results,
        super(provider: _NoopProvider());

  final List<WorkshopInferenceResult> _results;
  int calls = 0;
  final List<String> prompts = <String>[];
  final List<int?> maxTokensValues = <int?>[];

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
    final index = calls++;
    prompts.add(prompt);
    maxTokensValues.add(maxTokens);
    if (index >= _results.length) {
      throw StateError('Unexpected extra Engineer inference call.');
    }
    return _results[index];
  }
}

final class _NoopProvider implements RuntimeInferenceProvider {
  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) =>
      const Stream.empty();
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

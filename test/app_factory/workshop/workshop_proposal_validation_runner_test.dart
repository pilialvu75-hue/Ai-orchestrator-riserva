import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_validation_runner.dart';
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
  group('WorkshopProposalValidationRunner', () {
    test('routes staged diff only to Reviewer and keeps valid session awaiting approval',
        () async {
      final reviewer = _StaticGateway(
        result: const WorkshopInferenceResult(
          text:
              '{"valid":true,"summary":"Validation passed","checks":["diff checked"],"warnings":[]}',
          terminalState: InferenceTerminalState.success,
          model: 'reviewer-model',
        ),
      );
      final gateways = _gateways(reviewer);
      final session = await _validationSession();

      final verdict = await WorkshopProposalValidationRunner(
        inference: _stageInference(gateways),
      ).run(session: session);

      expect(verdict.valid, isTrue);
      expect(verdict.summary, 'Validation passed');
      expect(verdict.checks, contains('diff checked'));
      expect(session.status, WorkspaceSessionStatus.validation);
      expect(session.isApplyApproved, isFalse);
      expect(session.hasChanges, isTrue);
      expect(reviewer.calls, 1);
      expect(reviewer.lastPrompt, contains('"path":"lib/app.dart"'));
      expect(reviewer.lastPrompt, contains('"before":"old"'));
      expect(reviewer.lastPrompt, contains('"after":"new"'));
      expect(gateways[AppAiRole.workshopOrchestrator]!.calls, 0);
      expect(gateways[AppAiRole.architect]!.calls, 0);
      expect(gateways[AppAiRole.engineer]!.calls, 0);
    });

    test('rejected validation blocks without approving or applying', () async {
      final reviewer = _StaticGateway(
        result: const WorkshopInferenceResult(
          text:
              '{"valid":false,"summary":"Regression detected","checks":[],"warnings":["fix required"]}',
          terminalState: InferenceTerminalState.success,
        ),
      );
      final session = await _validationSession();

      final verdict = await WorkshopProposalValidationRunner(
        inference: _stageInference(_gateways(reviewer)),
      ).run(session: session);

      expect(verdict.valid, isFalse);
      expect(session.status, WorkspaceSessionStatus.blocked);
      expect(session.isApplyApproved, isFalse);
      expect(session.hasChanges, isTrue);
      expect(reviewer.calls, 1);
    });

    test('failed validation inference leaves session in validation', () async {
      final reviewer = _StaticGateway(
        result: const WorkshopInferenceResult(
          text: '',
          terminalState: InferenceTerminalState.failed,
          errorMessage: 'validation runtime failed',
        ),
      );
      final session = await _validationSession();

      await expectLater(
        WorkshopProposalValidationRunner(
          inference: _stageInference(_gateways(reviewer)),
        ).run(session: session),
        throwsA(isA<StateError>()),
      );

      expect(session.status, WorkspaceSessionStatus.validation);
      expect(session.isApplyApproved, isFalse);
      expect(session.hasChanges, isTrue);
      expect(reviewer.calls, 1);
    });
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

Map<AppAiRole, _StaticGateway> _gateways(_StaticGateway reviewer) {
  final idleResult = const WorkshopInferenceResult(
    text: '{}',
    terminalState: InferenceTerminalState.success,
  );

  return <AppAiRole, _StaticGateway>{
    AppAiRole.workshopOrchestrator: _StaticGateway(result: idleResult),
    AppAiRole.architect: _StaticGateway(result: idleResult),
    AppAiRole.engineer: _StaticGateway(result: idleResult),
    AppAiRole.reviewer: reviewer,
  };
}

Future<WorkspaceSession> _validationSession() async {
  final gateway = _RecordingWorkspaceGateway(
    files: <String, String>{'lib/app.dart': 'old'},
  );
  final session = WorkspaceSession(
    request: const WorkshopRequest(
      id: 'validation-runner-request',
      title: 'Validate staged change',
      instruction: 'Update the app implementation safely',
      constraints: <String>['Do not introduce regressions'],
    ),
    gateway: gateway,
  );

  await session.initialize();
  session.workspace.write(path: 'lib/app.dart', content: 'new');
  session.beginReview();
  session.beginValidation();
  return session;
}

final class _StaticGateway extends WorkshopInferenceGateway {
  _StaticGateway({required this.result}) : super(provider: _NoopProvider());

  final WorkshopInferenceResult result;
  int calls = 0;
  String? lastPrompt;

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
    lastPrompt = prompt;
    return result;
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
    throw StateError('Validation must not write the real workspace.');
  }

  @override
  Future<void> deleteFile(String path) async {
    throw StateError('Validation must not delete from the real workspace.');
  }

  @override
  Future<GitWorkspaceDiff> getDiff() async =>
      const GitWorkspaceDiff(files: <GitWorkspaceFileChange>[]);

  @override
  Future<String> commit(String message) async =>
      throw StateError('Validation must not commit.');

  @override
  Future<void> push() async {
    throw StateError('Validation must not push.');
  }

  @override
  Future<String> createPullRequest({
    required String title,
    required String body,
    required String headBranch,
    required String baseBranch,
  }) async =>
      throw StateError('Validation must not open a pull request.');
}

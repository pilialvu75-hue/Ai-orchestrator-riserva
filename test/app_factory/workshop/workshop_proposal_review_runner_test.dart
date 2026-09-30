import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_review_runner.dart';
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
  group('WorkshopProposalReviewRunner', () {
    test('routes staged diff only to Reviewer and advances approval to validation',
        () async {
      final reviewer = _StaticGateway(
        result: const WorkshopInferenceResult(
          text:
              '{"approved":true,"summary":"Review passed","findings":[],"warnings":[]}',
          terminalState: InferenceTerminalState.success,
          model: 'reviewer-model',
        ),
      );
      final gateways = _gateways(reviewer);
      final session = await _reviewSession();
      final longPlan = <String>[
        'Architect bounded task plan: implement walking tracking.',
        List<String>.filled(1200, 'middle').join(' '),
        'ACCEPTANCE: show visible user feedback for walking progress.',
      ].join('\n');

      final verdict = await WorkshopProposalReviewRunner(
        inference: _stageInference(gateways),
      ).run(
        session: session,
        implementationPlan: longPlan,
      );

      expect(verdict.approved, isTrue);
      expect(verdict.summary, 'Review passed');
      expect(session.status, WorkspaceSessionStatus.validation);
      expect(session.isApplyApproved, isFalse);
      expect(reviewer.calls, 1);
      expect(reviewer.lastPrompt, contains('"path":"lib/app.dart"'));
      expect(reviewer.lastPrompt, contains('"before":"old"'));
      expect(reviewer.lastPrompt, contains('"after":"new"'));
      expect(reviewer.lastPrompt, contains('SCOPE RULE:'));
      expect(reviewer.lastPrompt, contains('CONTRACT PRECEDENCE:'));
      expect(
        reviewer.lastPrompt,
        contains('GENERIC FLUTTER SCAFFOLD CONTRACT'),
      );
      expect(
        reviewer.lastPrompt,
        contains('pubspec.yaml is absent from the'),
      );
      expect(reviewer.lastPrompt, contains('UI LITERAL FIDELITY'));
      expect(reviewer.lastPrompt, contains('requested "+" becoming "+1"'));
      expect(
        reviewer.lastPrompt,
        contains('"targetFilesPolicy":"unspecified_for_initial_create_task"'),
      );
      expect(
        reviewer.lastPrompt,
        contains('explicit task instruction and explicit constraints are authoritative'),
      );
      expect(reviewer.lastPrompt, contains('does NOT mean'));
      expect(reviewer.lastPrompt, contains('no files are'));
      expect(
        reviewer.lastPrompt,
        contains('allowed" and is not by itself a mismatch'),
      );
      expect(
        reviewer.lastPrompt,
        isNot(contains('WORKSHOP_APPROVED_PROPOSAL:')),
      );
      expect(
        reviewer.lastPrompt,
        isNot(contains('future oxygen tracking')),
      );
      expect(reviewer.lastPrompt, contains('Project goal: walking app'));
      expect(reviewer.lastPrompt, contains('Architect bounded task plan'));
      expect(
        reviewer.lastPrompt,
        contains('ACCEPTANCE: show visible user feedback for walking progress.'),
      );
      expect(reviewer.lastPrompt, contains('[bounded middle omitted]'));
      expect(reviewer.lastPrompt, isNot(contains('true|false')));
      expect(reviewer.lastPrompt, contains('"approved" field MUST'));
      expect(
        gateways[AppAiRole.workshopOrchestrator]!.calls,
        0,
      );
      expect(gateways[AppAiRole.architect]!.calls, 0);
      expect(gateways[AppAiRole.engineer]!.calls, 0);
    });

    test('retries one transient Reviewer runtime failure with compact bounds',
        () async {
      final reviewer = _StaticGateway(
        result: const WorkshopInferenceResult(
          text: '',
          terminalState: InferenceTerminalState.failed,
        ),
        sequence: const <WorkshopInferenceResult>[
          WorkshopInferenceResult(
            text: '',
            terminalState: InferenceTerminalState.failed,
          ),
          WorkshopInferenceResult(
            text:
                '{"approved":true,"summary":"Retry passed","findings":[],"warnings":[]}',
            terminalState: InferenceTerminalState.success,
            model: 'reviewer-model',
          ),
        ],
      );
      final session = await _reviewSession();

      final verdict = await WorkshopProposalReviewRunner(
        inference: _stageInference(_gateways(reviewer)),
      ).run(
        session: session,
        implementationPlan: <String>[
          'Architect retry contract: implement walking tracking.',
          List<String>.filled(220, 'Architect plan').join(' '),
          'ACCEPTANCE: visible user feedback remains required.',
        ].join('\n'),
      );

      expect(verdict.approved, isTrue);
      expect(session.status, WorkspaceSessionStatus.validation);
      expect(reviewer.calls, 2);
      expect(reviewer.maxTokensSeen, <int?>[256, 192]);
      expect(
        reviewer.firstTokenTimeoutsSeen,
        <Duration?>[null, const Duration(seconds: 75)],
      );
      expect(reviewer.sessionIdsSeen.last, endsWith(':retry-1'));
      expect(reviewer.promptsSeen, hasLength(2));
      expect(
        reviewer.promptsSeen.last.length,
        lessThanOrEqualTo(reviewer.promptsSeen.first.length),
      );
      expect(
        reviewer.promptsSeen,
        everyElement(
          contains('ACCEPTANCE: visible user feedback remains required.'),
        ),
      );
      expect(
        reviewer.promptsSeen,
        everyElement(contains('[bounded middle omitted]')),
      );
    });

    test('reviews every staged file before aggregate approval', () async {
      final reviewer = _StaticGateway(
        result: const WorkshopInferenceResult(
          text:
              '{"approved":true,"summary":"Batch passed","findings":[],"warnings":[]}',
          terminalState: InferenceTerminalState.success,
        ),
        sequence: const <WorkshopInferenceResult>[
          WorkshopInferenceResult(
            text:
                '{"approved":true,"summary":"Batch 1 passed","findings":[],"warnings":[]}',
            terminalState: InferenceTerminalState.success,
          ),
          WorkshopInferenceResult(
            text:
                '{"approved":true,"summary":"Batch 2 passed","findings":[],"warnings":[]}',
            terminalState: InferenceTerminalState.success,
          ),
          WorkshopInferenceResult(
            text:
                '{"approved":true,"summary":"Batch 3 passed","findings":[],"warnings":[]}',
            terminalState: InferenceTerminalState.success,
          ),
        ],
      );
      final session = await _reviewSessionWithChangedFiles(5);

      final verdict = await WorkshopProposalReviewRunner(
        inference: _stageInference(_gateways(reviewer)),
      ).run(
        session: session,
        implementationPlan: 'Architect bounded task plan',
      );

      expect(verdict.approved, isTrue);
      expect(session.status, WorkspaceSessionStatus.validation);
      expect(reviewer.calls, 3);
      expect(reviewer.promptsSeen, hasLength(3));
      expect(
        reviewer.promptsSeen,
        everyElement(contains('"coverageManifest"')),
      );
      for (var index = 1; index <= 5; index += 1) {
        expect(
          reviewer.promptsSeen
              .where((prompt) => prompt.contains('"after":"new-$index"')),
          hasLength(1),
          reason: 'Each staged file body must be reviewed exactly once.',
        );
      }
      expect(
        reviewer.promptsSeen.last,
        contains('"paths":["lib/file_5.dart"]'),
      );
    });

    test('a rejected intermediate batch blocks aggregate approval', () async {
      final reviewer = _StaticGateway(
        result: const WorkshopInferenceResult(
          text:
              '{"approved":false,"summary":"Batch rejected","findings":["bug"],"warnings":[]}',
          terminalState: InferenceTerminalState.success,
        ),
        sequence: const <WorkshopInferenceResult>[
          WorkshopInferenceResult(
            text:
                '{"approved":true,"summary":"Batch 1 passed","findings":[],"warnings":[]}',
            terminalState: InferenceTerminalState.success,
          ),
          WorkshopInferenceResult(
            text:
                '{"approved":false,"summary":"Batch 2 rejected","findings":["bug"],"warnings":[]}',
            terminalState: InferenceTerminalState.success,
          ),
        ],
      );
      final session = await _reviewSessionWithChangedFiles(5);

      final verdict = await WorkshopProposalReviewRunner(
        inference: _stageInference(_gateways(reviewer)),
      ).run(session: session);

      expect(verdict.approved, isFalse);
      expect(verdict.summary, 'Batch 2 rejected');
      expect(session.status, WorkspaceSessionStatus.blocked);
      expect(session.isApplyApproved, isFalse);
      expect(reviewer.calls, 2);
      expect(
        reviewer.promptsSeen.any((prompt) => prompt.contains('"after":"new-5"')),
        isFalse,
      );
    });

    test('changing the staged diff invalidates prior batch approval', () async {
      late WorkspaceSession session;
      final reviewer = _StaticGateway(
        result: const WorkshopInferenceResult(
          text:
              '{"approved":true,"summary":"Batch passed","findings":[],"warnings":[]}',
          terminalState: InferenceTerminalState.success,
        ),
        onCall: (index) {
          if (index == 0) {
            session.workspace.write(
              path: 'lib/file_3.dart',
              content: 'changed-during-review',
            );
          }
        },
      );
      session = await _reviewSessionWithChangedFiles(3);

      await expectLater(
        WorkshopProposalReviewRunner(
          inference: _stageInference(_gateways(reviewer)),
        ).run(session: session),
        throwsA(isA<StateError>()),
      );

      expect(session.status, WorkspaceSessionStatus.review);
      expect(session.isApplyApproved, isFalse);
      expect(reviewer.calls, 1);
    });

    test('failed Reviewer inference leaves staged workspace in review',
        () async {
      final reviewer = _StaticGateway(
        result: const WorkshopInferenceResult(
          text: '',
          terminalState: InferenceTerminalState.failed,
          errorMessage: 'review runtime failed',
        ),
      );
      final session = await _reviewSession();

      await expectLater(
        WorkshopProposalReviewRunner(
          inference: _stageInference(_gateways(reviewer)),
        ).run(session: session),
        throwsA(isA<StateError>()),
      );

      expect(session.status, WorkspaceSessionStatus.review);
      expect(session.hasChanges, isTrue);
      expect(session.isApplyApproved, isFalse);
      expect(reviewer.calls, 2);
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
  const idleResult = WorkshopInferenceResult(
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

Future<WorkspaceSession> _reviewSession() async {
  final gateway = _RecordingWorkspaceGateway(
    files: <String, String>{'lib/app.dart': 'old'},
  );
  final session = WorkspaceSession(
    request: const WorkshopRequest(
      id: 'review-runner-request',
      title: 'Review staged change',
      instruction: 'Update the app implementation safely',
      constraints: <String>['Do not introduce regressions'],
      context: <String>[
        'WORKSHOP_APPROVED_PROPOSAL:future oxygen tracking and navigation',
        'Project goal: walking app',
      ],
    ),
    gateway: gateway,
  );

  await session.initialize();
  session.workspace.write(path: 'lib/app.dart', content: 'new');
  session.beginReview();
  return session;
}

Future<WorkspaceSession> _reviewSessionWithChangedFiles(int count) async {
  final files = <String, String>{
    for (var index = 1; index <= count; index += 1)
      'lib/file_$index.dart': 'old-$index',
  };
  final gateway = _RecordingWorkspaceGateway(files: files);
  final session = WorkspaceSession(
    request: const WorkshopRequest(
      id: 'review-runner-multi-file-request',
      title: 'Review all staged changes',
      instruction: 'Update every staged file safely',
      constraints: <String>['Do not introduce regressions'],
      context: <String>['Project goal: walking app'],
    ),
    gateway: gateway,
  );

  await session.initialize();
  for (var index = 1; index <= count; index += 1) {
    session.workspace.write(
      path: 'lib/file_$index.dart',
      content: 'new-$index',
    );
  }
  session.beginReview();
  return session;
}

final class _StaticGateway extends WorkshopInferenceGateway {
  _StaticGateway({
    required this.result,
    this.sequence = const <WorkshopInferenceResult>[],
    this.onCall,
  }) : super(provider: _NoopProvider());

  final WorkshopInferenceResult result;
  final List<WorkshopInferenceResult> sequence;
  final void Function(int index)? onCall;
  int calls = 0;
  String? lastPrompt;
  final List<String> promptsSeen = <String>[];
  final List<int?> maxTokensSeen = <int?>[];
  final List<String> sessionIdsSeen = <String>[];
  final List<Duration?> firstTokenTimeoutsSeen = <Duration?>[];

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
    final index = calls;
    calls += 1;
    lastPrompt = prompt;
    promptsSeen.add(prompt);
    maxTokensSeen.add(maxTokens);
    sessionIdsSeen.add(sessionId);
    firstTokenTimeoutsSeen.add(null);
    onCall?.call(index);
    if (sequence.isNotEmpty) {
      return sequence[index < sequence.length ? index : sequence.length - 1];
    }
    return result;
  }

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
  }) async {
    final index = calls;
    calls += 1;
    lastPrompt = prompt;
    promptsSeen.add(prompt);
    maxTokensSeen.add(maxTokens);
    sessionIdsSeen.add(sessionId);
    firstTokenTimeoutsSeen.add(firstTokenTimeout);
    onCall?.call(index);
    if (sequence.isNotEmpty) {
      return sequence[index < sequence.length ? index : sequence.length - 1];
    }
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
    throw StateError('Review must not write the real workspace.');
  }

  @override
  Future<void> deleteFile(String path) async {
    throw StateError('Review must not delete from the real workspace.');
  }

  @override
  Future<GitWorkspaceDiff> getDiff() async =>
      const GitWorkspaceDiff(files: <GitWorkspaceFileChange>[]);

  @override
  Future<String> commit(String message) async =>
      throw StateError('Review must not commit.');

  @override
  Future<void> push() async {
    throw StateError('Review must not push.');
  }

  @override
  Future<String> createPullRequest({
    required String title,
    required String body,
    required String headBranch,
    required String baseBranch,
  }) async =>
      throw StateError('Review must not open a pull request.');
}

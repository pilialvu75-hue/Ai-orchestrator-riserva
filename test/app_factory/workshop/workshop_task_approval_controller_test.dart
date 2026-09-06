import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_apply_approval_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_approval_controller.dart';

void main() {
  group('WorkshopTaskApprovalController', () {
    test('approval is recorded without writing until explicit apply', () async {
      final gateway = _RecordingGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final executor = WorkshopProjectExecutor(gateway: gateway);
      final controller = WorkshopTaskApprovalController(executor: executor);
      final session = await _validatedSession(executor);

      final decided = controller.decide(
        taskId: 'task:apply',
        decision: WorkshopApplyDecision.approve,
      );

      expect(identical(decided, session), isTrue);
      expect(session.status, WorkspaceSessionStatus.approved);
      expect(session.isApplyApproved, isTrue);
      expect(gateway.files['lib/app.dart'], 'old');
      expect(gateway.writeCalls, 0);
      expect(gateway.commitCalls, 0);
      expect(gateway.pushCalls, 0);
      expect(gateway.pullRequestCalls, 0);

      final applied = await controller.applyApproved('task:apply');

      expect(identical(applied, session), isTrue);
      expect(session.status, WorkspaceSessionStatus.completed);
      expect(session.isApplyApproved, isFalse);
      expect(gateway.files['lib/app.dart'], 'new');
      expect(gateway.writeCalls, 1);
      expect(gateway.commitCalls, 0);
      expect(gateway.pushCalls, 0);
      expect(gateway.pullRequestCalls, 0);
    });

    test('rejection blocks without applying staged changes', () async {
      final gateway = _RecordingGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final executor = WorkshopProjectExecutor(gateway: gateway);
      final controller = WorkshopTaskApprovalController(executor: executor);
      final session = await _validatedSession(executor);

      controller.decide(
        taskId: 'task:apply',
        decision: WorkshopApplyDecision.reject,
        rejectionReason: 'Owner rejected generated changes.',
      );

      expect(session.status, WorkspaceSessionStatus.blocked);
      expect(session.blockedReason, 'Owner rejected generated changes.');
      expect(session.isApplyApproved, isFalse);
      expect(gateway.files['lib/app.dart'], 'old');
      expect(gateway.writeCalls, 0);

      await expectLater(
        controller.applyApproved('task:apply'),
        throwsA(isA<StateError>()),
      );

      expect(gateway.files['lib/app.dart'], 'old');
      expect(gateway.writeCalls, 0);
    });

    test('cannot approve before validation', () async {
      final gateway = _RecordingGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final executor = WorkshopProjectExecutor(gateway: gateway);
      final controller = WorkshopTaskApprovalController(executor: executor);
      final session = await executor.prepareTask(_plan(), 'task:apply');

      session.workspace.write(path: 'lib/app.dart', content: 'new');
      session.beginReview();

      expect(
        () => controller.decide(
          taskId: 'task:apply',
          decision: WorkshopApplyDecision.approve,
        ),
        throwsA(isA<StateError>()),
      );

      expect(session.status, WorkspaceSessionStatus.review);
      expect(session.isApplyApproved, isFalse);
      expect(gateway.writeCalls, 0);
    });
  });
}

Future<WorkspaceSession> _validatedSession(
  WorkshopProjectExecutor executor,
) async {
  final session = await executor.prepareTask(_plan(), 'task:apply');
  session.workspace.write(path: 'lib/app.dart', content: 'new');
  session.beginReview();
  session.beginValidation();
  return session;
}

WorkshopProjectPlan _plan() {
  return WorkshopProjectPlan(
    id: 'project:approval',
    title: 'Approval project',
    goal: 'Apply one validated change',
    status: WorkshopProjectStatus.planned,
    phases: <WorkshopProjectPhase>[
      WorkshopProjectPhase(
        id: 'phase:implementation',
        title: 'Implementation',
        description: 'Apply one validated task',
        taskIds: const <String>['task:apply'],
      ),
    ],
    tasks: <WorkshopProjectTask>[
      WorkshopProjectTask(
        id: 'task:apply',
        title: 'Modify app',
        description: 'Modify the app file',
        phaseId: 'phase:implementation',
        affectedPaths: const <String>['lib/app.dart'],
      ),
    ],
  );
}

final class _RecordingGateway implements GitWorkspaceGateway {
  _RecordingGateway({required Map<String, String> files})
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

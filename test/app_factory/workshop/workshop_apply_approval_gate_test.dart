import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_apply_approval_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';

void main() {
  group('WorkshopApplyApprovalGate', () {
    test('explicit approval authorizes but does not apply real writes', () async {
      final gateway = _RecordingGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final session = await _validatedSession(gateway);

      const WorkshopApplyApprovalGate().decide(
        session: session,
        decision: WorkshopApplyDecision.approve,
      );

      expect(session.status, WorkspaceSessionStatus.approved);
      expect(session.isApplyApproved, isTrue);
      expect(gateway.writeCalls, 0);
      expect(gateway.deleteCalls, 0);
      expect(gateway.commitCalls, 0);
      expect(gateway.pushCalls, 0);
      expect(gateway.pullRequestCalls, 0);
    });

    test('rejection blocks the session without applying real writes', () async {
      final gateway = _RecordingGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final session = await _validatedSession(gateway);

      const WorkshopApplyApprovalGate().decide(
        session: session,
        decision: WorkshopApplyDecision.reject,
        rejectionReason: 'Owner rejected generated changes.',
      );

      expect(session.status, WorkspaceSessionStatus.blocked);
      expect(session.blockedReason, 'Owner rejected generated changes.');
      expect(session.isApplyApproved, isFalse);
      expect(gateway.writeCalls, 0);
      expect(gateway.deleteCalls, 0);
    });

    test('approval cannot bypass validation', () async {
      final gateway = _RecordingGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final session = WorkspaceSession(
        request: const WorkshopRequest(
          id: 'approval-request',
          title: 'Approve staged proposal',
          instruction: 'Approve only after validation',
        ),
        gateway: gateway,
      );
      await session.initialize();
      session.workspace.write(path: 'lib/app.dart', content: 'new');
      session.beginReview();

      expect(
        () => const WorkshopApplyApprovalGate().decide(
          session: session,
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

Future<WorkspaceSession> _validatedSession(_RecordingGateway gateway) async {
  final session = WorkspaceSession(
    request: const WorkshopRequest(
      id: 'approval-request',
      title: 'Approve staged proposal',
      instruction: 'Approve only after validation',
    ),
    gateway: gateway,
  );

  await session.initialize();
  session.workspace.write(path: 'lib/app.dart', content: 'new');
  session.beginReview();
  session.beginValidation();
  return session;
}

final class _RecordingGateway implements GitWorkspaceGateway {
  _RecordingGateway({required Map<String, String> files})
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

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_approved_apply_runner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';

void main() {
  group('WorkshopApprovedApplyRunner', () {
    test('applies staged changes only after explicit owner approval', () async {
      final gateway = _RecordingGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final session = await _approvedSession(gateway);

      await const WorkshopApprovedApplyRunner().run(session: session);

      expect(session.status, WorkspaceSessionStatus.completed);
      expect(session.isApplyApproved, isFalse);
      expect(gateway.writeCalls, 1);
      expect(gateway.files['lib/app.dart'], 'new');
      expect(gateway.commitCalls, 0);
      expect(gateway.pushCalls, 0);
      expect(gateway.pullRequestCalls, 0);
    });

    test('refuses real writes before explicit owner approval', () async {
      final gateway = _RecordingGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final session = await _validatedSession(gateway);

      await expectLater(
        const WorkshopApprovedApplyRunner().run(session: session),
        throwsA(isA<StateError>()),
      );

      expect(session.status, WorkspaceSessionStatus.validation);
      expect(gateway.writeCalls, 0);
      expect(gateway.deleteCalls, 0);
      expect(gateway.commitCalls, 0);
      expect(gateway.pushCalls, 0);
      expect(gateway.pullRequestCalls, 0);
    });
  });
}

Future<WorkspaceSession> _approvedSession(_RecordingGateway gateway) async {
  final session = await _validatedSession(gateway);
  session.approveApply();
  return session;
}

Future<WorkspaceSession> _validatedSession(_RecordingGateway gateway) async {
  final session = WorkspaceSession(
    request: const WorkshopRequest(
      id: 'approved-apply-request',
      title: 'Apply validated proposal',
      instruction: 'Apply only after explicit owner approval',
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

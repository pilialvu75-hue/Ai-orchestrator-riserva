import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_review_gate.dart';
import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';

void main() {
  group('WorkshopProposalReviewGate', () {
    test('approved Reviewer verdict advances review to validation without writes',
        () async {
      final gateway = _RecordingGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final session = await _reviewSession(gateway);

      final verdict = const WorkshopProposalReviewGate().evaluate(
        session: session,
        responseText: '''
{
  "approved": true,
  "summary": "Review passed",
  "findings": ["Implementation matches the requested change"],
  "warnings": []
}
''',
      );

      expect(verdict.approved, isTrue);
      expect(verdict.summary, 'Review passed');
      expect(verdict.findings, hasLength(1));
      expect(session.status, WorkspaceSessionStatus.validation);
      expect(session.isApplyApproved, isFalse);
      expect(gateway.writeCalls, 0);
      expect(gateway.deleteCalls, 0);
      expect(gateway.commitCalls, 0);
      expect(gateway.pushCalls, 0);
      expect(gateway.pullRequestCalls, 0);
    });

    test('rejected Reviewer verdict blocks the session without applying changes',
        () async {
      final gateway = _RecordingGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final session = await _reviewSession(gateway);

      final verdict = const WorkshopProposalReviewGate().evaluate(
        session: session,
        responseText: '''
{"approved":false,"summary":"Tests are missing","findings":["Add a regression test"]}
''',
      );

      expect(verdict.approved, isFalse);
      expect(session.status, WorkspaceSessionStatus.blocked);
      expect(session.blockedReason, 'Tests are missing');
      expect(session.isApplyApproved, isFalse);
      expect(gateway.writeCalls, 0);
      expect(gateway.deleteCalls, 0);
      expect(gateway.commitCalls, 0);
      expect(gateway.pushCalls, 0);
      expect(gateway.pullRequestCalls, 0);
    });

    test('malformed Reviewer output leaves the session in review', () async {
      final gateway = _RecordingGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final session = await _reviewSession(gateway);

      expect(
        () => const WorkshopProposalReviewGate().evaluate(
          session: session,
          responseText: '{"approved":"yes","summary":"bad"}',
        ),
        throwsA(isA<FormatException>()),
      );

      expect(session.status, WorkspaceSessionStatus.review);
      expect(session.isApplyApproved, isFalse);
      expect(gateway.writeCalls, 0);
      expect(gateway.deleteCalls, 0);
    });
  });
}

Future<WorkspaceSession> _reviewSession(_RecordingGateway gateway) async {
  final session = WorkspaceSession(
    request: const WorkshopRequest(
      id: 'review-request',
      title: 'Review staged proposal',
      instruction: 'Review the implementation',
    ),
    gateway: gateway,
  );

  await session.initialize();
  session.workspace.write(path: 'lib/app.dart', content: 'new');
  session.beginReview();
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

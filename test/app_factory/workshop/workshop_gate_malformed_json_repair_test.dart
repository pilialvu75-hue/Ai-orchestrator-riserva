import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_diff.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_review_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_validation_gate.dart';

void main() {
  test('repairs physical-style literal newline in Reviewer summary', () async {
    final gateway = _RecordingGateway(
      files: <String, String>{'lib/main.dart': 'old'},
    );
    final session = await _reviewSession(gateway);

    final verdict = const WorkshopProposalReviewGate().evaluate(
      session: session,
      responseText: '''
{
  "approved": true,
  "summary": "The change to lib/main.dart implements
  the requested Manga Kids build repair",
  "findings": [],
  "warnings": []
}
''',
    );

    expect(verdict.approved, isTrue);
    expect(
      verdict.summary,
      'The change to lib/main.dart implements\n  the requested Manga Kids build repair',
    );
    expect(session.status, WorkspaceSessionStatus.validation);
    expect(gateway.writeCalls, 0);
  });

  test('repairs physical-style literal newline in validation summary', () async {
    final gateway = _RecordingGateway(
      files: <String, String>{'lib/main.dart': 'old'},
    );
    final session = await _reviewSession(gateway);
    session.beginValidation();

    final verdict = const WorkshopProposalValidationGate().evaluate(
      session: session,
      responseText: '''
{
  "valid": true,
  "summary": "The staged repair is valid
  and preserves the requested behavior",
  "checks": [],
  "warnings": []
}
''',
    );

    expect(verdict.valid, isTrue);
    expect(
      verdict.summary,
      'The staged repair is valid\n  and preserves the requested behavior',
    );
    expect(session.status, WorkspaceSessionStatus.validation);
    expect(session.isApplyApproved, isFalse);
    expect(gateway.writeCalls, 0);
  });

  test('structural reviewer fields remain strict after repair support', () async {
    final gateway = _RecordingGateway(
      files: <String, String>{'lib/main.dart': 'old'},
    );
    final session = await _reviewSession(gateway);

    expect(
      () => const WorkshopProposalReviewGate().evaluate(
        session: session,
        responseText: '''
{
  "approved": "true",
  "summary": "looks good
  enough",
  "findings": [],
  "warnings": []
}
''',
      ),
      throwsFormatException,
    );

    expect(session.status, WorkspaceSessionStatus.review);
    expect(gateway.writeCalls, 0);
  });
}

Future<WorkspaceSession> _reviewSession(_RecordingGateway gateway) async {
  final session = WorkspaceSession(
    request: const WorkshopRequest(
      id: 'malformed-gate-repair',
      title: 'Manga Kids build repair',
      instruction: 'Repair the staged generated app safely.',
      targetFiles: <String>['lib/main.dart'],
    ),
    gateway: gateway,
  );

  await session.initialize();
  session.workspace.write(path: 'lib/main.dart', content: 'new');
  session.beginReview();
  return session;
}

final class _RecordingGateway implements GitWorkspaceGateway {
  _RecordingGateway({required Map<String, String> files})
      : _files = Map<String, String>.from(files);

  final Map<String, String> _files;
  int writeCalls = 0;

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

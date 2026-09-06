import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_validation_gate.dart';
import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';

void main() {
  group('WorkshopProposalValidationGate', () {
    test('valid verdict keeps validation separate from approval and apply',
        () async {
      final gateway = _RecordingGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final session = await _validationSession(gateway);

      final verdict = const WorkshopProposalValidationGate().evaluate(
        session: session,
        responseText: '''
{
  "valid": true,
  "summary": "Validation passed",
  "checks": ["Diff is internally consistent"],
  "warnings": []
}
''',
      );

      expect(verdict.valid, isTrue);
      expect(verdict.summary, 'Validation passed');
      expect(verdict.checks, hasLength(1));
      expect(session.status, WorkspaceSessionStatus.validation);
      expect(session.isApplyApproved, isFalse);
      expect(gateway.writeCalls, 0);
      expect(gateway.deleteCalls, 0);
      expect(gateway.commitCalls, 0);
      expect(gateway.pushCalls, 0);
      expect(gateway.pullRequestCalls, 0);
    });

    test('invalid verdict blocks the session without applying changes',
        () async {
      final gateway = _RecordingGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final session = await _validationSession(gateway);

      final verdict = const WorkshopProposalValidationGate().evaluate(
        session: session,
        responseText: '''
{"valid":false,"summary":"Validation failed","checks":["Generated file is incomplete"]}
''',
      );

      expect(verdict.valid, isFalse);
      expect(session.status, WorkspaceSessionStatus.blocked);
      expect(session.blockedReason, 'Validation failed');
      expect(session.isApplyApproved, isFalse);
      expect(gateway.writeCalls, 0);
      expect(gateway.deleteCalls, 0);
      expect(gateway.commitCalls, 0);
      expect(gateway.pushCalls, 0);
      expect(gateway.pullRequestCalls, 0);
    });

    test('malformed validation output leaves the session in validation',
        () async {
      final gateway = _RecordingGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final session = await _validationSession(gateway);

      expect(
        () => const WorkshopProposalValidationGate().evaluate(
          session: session,
          responseText: '{"valid":"yes","summary":"bad"}',
        ),
        throwsA(isA<FormatException>()),
      );

      expect(session.status, WorkspaceSessionStatus.validation);
      expect(session.isApplyApproved, isFalse);
      expect(gateway.writeCalls, 0);
      expect(gateway.deleteCalls, 0);
    });
  });
}

Future<WorkspaceSession> _validationSession(_RecordingGateway gateway) async {
  final session = WorkspaceSession(
    request: const WorkshopRequest(
      id: 'validation-request',
      title: 'Validate staged proposal',
      instruction: 'Validate the reviewed implementation',
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

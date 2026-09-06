import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_workspace_stager.dart';
import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';

void main() {
  group('WorkshopProposalWorkspaceStager', () {
    test('decodes Engineer output into VirtualWorkspace without remote writes',
        () async {
      final gateway = _RecordingGateway(
        files: <String, String>{
          'lib/existing.dart': 'old',
          'lib/remove.dart': 'remove me',
        },
      );
      final session = WorkspaceSession(
        request: const WorkshopRequest(
          id: 'request-1',
          title: 'Implement change',
          instruction: 'Update the project',
        ),
        gateway: gateway,
      );
      await session.initialize();

      final proposal = const WorkshopProposalWorkspaceStager().stage(
        session: session,
        responseText: '''
{
  "explanation": "Implement requested change",
  "changes": [
    {"path":"lib/existing.dart","type":"update","content":"new"},
    {"path":"lib/new.dart","type":"create","content":"created"},
    {"path":"lib/remove.dart","type":"delete"}
  ]
}
''',
      );

      expect(proposal.requestId, 'request-1');
      expect(session.status, WorkspaceSessionStatus.working);
      expect(session.workspace.read('lib/existing.dart'), 'new');
      expect(session.workspace.read('lib/new.dart'), 'created');
      expect(session.workspace.contains('lib/remove.dart'), isFalse);
      expect(session.changeCount, 3);

      expect(gateway.writeCalls, 0);
      expect(gateway.deleteCalls, 0);
      expect(gateway.commitCalls, 0);
      expect(gateway.pushCalls, 0);
      expect(gateway.pullRequestCalls, 0);
    });

    test('does not materialize malformed output', () async {
      final gateway = _RecordingGateway(
        files: <String, String>{'lib/existing.dart': 'old'},
      );
      final session = WorkspaceSession(
        request: const WorkshopRequest(
          id: 'request-2',
          title: 'Unsafe change',
          instruction: 'Try malformed output',
        ),
        gateway: gateway,
      );
      await session.initialize();

      expect(
        () => const WorkshopProposalWorkspaceStager().stage(
          session: session,
          responseText: '''
{"explanation":"bad","changes":[{"path":"../escape.dart","type":"create","content":"x"}]}
''',
        ),
        throwsA(isA<FormatException>()),
      );

      expect(session.hasChanges, isFalse);
      expect(session.status, WorkspaceSessionStatus.ready);
      expect(gateway.writeCalls, 0);
      expect(gateway.deleteCalls, 0);
    });
  });
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

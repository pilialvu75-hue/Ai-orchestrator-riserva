import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_workspace_stager.dart';
import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';

void main() {
  group('WorkshopProposalWorkspaceStager', () {
    test(
        'decodes Engineer output into VirtualWorkspace and enters review without remote writes',
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
      expect(session.status, WorkspaceSessionStatus.review);
      expect(session.isApplyApproved, isFalse);
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


    test('rejects a proposal that escapes an explicit task target scope',
        () async {
      final gateway = _RecordingGateway(files: <String, String>{});
      final session = WorkspaceSession(
        request: const WorkshopRequest(
          id: 'request-scope',
          title: 'Add widget test',
          instruction: 'Add the bounded verification only.',
          targetFiles: <String>['test/widget_test.dart'],
        ),
        gateway: gateway,
      );
      await session.initialize();

      expect(
        () => const WorkshopProposalWorkspaceStager().stage(
          session: session,
          responseText: '''
{"explanation":"test","changes":[{"path":"lib/test/widget_test.dart","type":"create","content":"void main() {}"}]}
''',
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('outside the current task targetFiles'),
          ),
        ),
      );

      expect(session.hasChanges, isFalse);
      expect(session.status, WorkspaceSessionStatus.ready);
    });

    test('rejects non-empty proposal that produces no staged diff',
        () async {
      final gateway = _RecordingGateway(
        files: <String, String>{'lib/main.dart': 'void main() {}'},
      );
      final session = WorkspaceSession(
        request: const WorkshopRequest(
          id: 'request-noop',
          title: 'Build repair',
          instruction: 'Repair the existing app.',
          operation: WorkshopOperation.fix,
          targetFiles: <String>['lib/main.dart'],
        ),
        gateway: gateway,
      );
      await session.initialize();

      expect(
        () => const WorkshopProposalWorkspaceStager().stage(
          session: session,
          responseText:
              '{"explanation":"No-op repair","changes":[{"path":"lib/main.dart","type":"modification","content":"void main() {}"}]}',
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('no staged workspace changes'),
          ),
        ),
      );

      expect(session.hasChanges, isFalse);
      expect(session.status, WorkspaceSessionStatus.ready);
      expect(session.workspace.read('lib/main.dart'), 'void main() {}');
      expect(gateway.writeCalls, 0);
      expect(gateway.deleteCalls, 0);
    });

    test('create task cannot omit a required missing lib/main.dart target',
        () async {
      final gateway = _RecordingGateway(files: <String, String>{});
      final session = WorkspaceSession(
        request: const WorkshopRequest(
          id: 'request-entrypoint',
          title: 'Create Flutter app',
          instruction: 'Create the app.',
          operation: WorkshopOperation.create,
          targetFiles: <String>['lib/main.dart', 'lib/app.dart'],
        ),
        gateway: gateway,
      );
      await session.initialize();

      expect(
        () => const WorkshopProposalWorkspaceStager().stage(
          session: session,
          responseText: '''
{"explanation":"app","changes":[{"path":"lib/app.dart","type":"create","content":"class App {}"}]}
''',
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('lib/main.dart'),
          ),
        ),
      );

      expect(session.hasChanges, isFalse);
      expect(session.status, WorkspaceSessionStatus.ready);
    });

    test('rejects +3140 JVM import in Dart before staging or review',
        () async {
      final gateway = _RecordingGateway(files: <String, String>{});
      final session = WorkspaceSession(
        request: const WorkshopRequest(
          id: 'physical-3140-mixed-source',
          title: 'Flutter Android star color on tap',
          instruction: 'Build a star with black background.',
          operation: WorkshopOperation.create,
          targetFiles: <String>['lib/main.dart'],
        ),
        gateway: gateway,
      );
      await session.initialize();
      final payload = jsonEncode(<String, Object?>{
        'explanation': 'Wrong cross-language import',
        'changes': <Map<String, String>>[
          <String, String>{
            'path': 'lib/main.dart',
            'type': 'addition',
            'content':
                "import 'com.example.myapp.MyStarView' as star;\\nvoid main() {}",
          },
        ],
      });

      expect(
        () => const WorkshopProposalWorkspaceStager().stage(
          session: session,
          responseText: payload,
        ),
        throwsA(isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('Android/JVM class directly'),
        )),
      );
      expect(session.status, WorkspaceSessionStatus.ready);
      expect(session.hasChanges, isFalse);
      expect(session.workspace.contains('lib/main.dart'), isFalse);
      expect(gateway.writeCalls, 0);
    });

    test('keeps legal Flutter imports and native platform files permitted',
        () async {
      final gateway = _RecordingGateway(files: <String, String>{});
      final session = WorkspaceSession(
        request: const WorkshopRequest(
          id: 'legal-flutter-source',
          title: 'Flutter app with native platform integration',
          instruction: 'Add a Flutter entry point and platform channel.',
          operation: WorkshopOperation.create,
          targetFiles: <String>[],
        ),
        gateway: gateway,
      );
      await session.initialize();
      final payload = jsonEncode(<String, Object?>{
        'explanation': 'Valid Dart imports with optional native code',
        'changes': <Map<String, String>>[
          <String, String>{
            'path': 'lib/main.dart',
            'type': 'addition',
            'content': "import 'package:flutter/material.dart';\\nvoid main() {}",
          },
          <String, String>{
            'path': 'android/app/src/main/kotlin/example/NativeBridge.kt',
            'type': 'addition',
            'content': 'class NativeBridge {}',
          },
        ],
      });

      const WorkshopProposalWorkspaceStager().stage(
        session: session,
        responseText: payload,
      );
      expect(session.status, WorkspaceSessionStatus.review);
      expect(session.workspace.contains('lib/main.dart'), isTrue);
      expect(session.workspace.contains(
        'android/app/src/main/kotlin/example/NativeBridge.kt',
      ), isTrue);
      expect(gateway.writeCalls, 0);
    });

    for (final nativeImport in <String>[
      "import 'java.util.Date';\nvoid main() {}",
      "import 'kotlin.collections.List';\nvoid main() {}",
      "import 'javax.net.Socket';\nvoid main() {}",
      "import /* legal comment */ 'android.graphics.Canvas';\nvoid main() {}",
    ]) {
      test('rejects actual JVM import before staging: $nativeImport',
          () async {
        final gateway = _RecordingGateway(files: <String, String>{});
        final session = WorkspaceSession(
          request: const WorkshopRequest(
            id: 'reject-real-jvm-import',
            title: 'Flutter entry point',
            instruction: 'Use Dart widget classes.',
            operation: WorkshopOperation.create,
            targetFiles: <String>['lib/main.dart'],
          ),
          gateway: gateway,
        );
        await session.initialize();
        final response = jsonEncode(<String, Object?>{
          'explanation': 'Invalid native class in Dart import',
          'changes': <Map<String, String>>[
            <String, String>{
              'path': 'lib/main.dart',
              'type': 'addition',
              'content': nativeImport,
            },
          ],
        });
        expect(
          () => const WorkshopProposalWorkspaceStager().stage(
            session: session,
            responseText: response,
          ),
          throwsA(isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('Android/JVM class directly'),
          )),
        );
        expect(session.hasChanges, isFalse);
        expect(session.status, WorkspaceSessionStatus.ready);
        expect(gateway.writeCalls, 0);
      });
    }

    for (final harmlessCode in <String>[
      "/*\nimport 'com.example.Foo';\n*/\nvoid main() {}",
      "// import 'java.util.Date';\nvoid main() {}",
      "/* outer\n /* nested\n import 'kotlin.collections.List';\n */\n */\nvoid main() {}",
      "const documentation = \"\"\"\nimport 'com.example.Foo';\n\"\"\";\nvoid main() {}",
      "const documentation = r'''\nimport 'java.util.Date';\n''';\nvoid main() {}",
      "const documentation = '''\nimport 'kotlin.collections.List';\n''';\nvoid main() {}",
      "void main() { print(\"import 'com.example.Foo';\"); }",
      "/* comment */ import 'package:flutter/material.dart';\nvoid main() {}",
      "import 'dart:math';\nimport 'package:flutter/material.dart';\nimport 'widgets/star.dart';\nvoid main() {}",
    ]) {
      test('keeps import-looking text in comments/strings legal: $harmlessCode',
          () async {
        final gateway = _RecordingGateway(files: <String, String>{});
        final session = WorkspaceSession(
          request: const WorkshopRequest(
            id: 'ignore-non-directive-import',
            title: 'Flutter source with documentation',
            instruction: 'Keep comment and string literals intact.',
            operation: WorkshopOperation.create,
            targetFiles: <String>['lib/main.dart'],
          ),
          gateway: gateway,
        );
        await session.initialize();
        final response = jsonEncode(<String, Object?>{
          'explanation': 'Existing comment or string literal content',
          'changes': <Map<String, String>>[
            <String, String>{
              'path': 'lib/main.dart',
              'type': 'addition',
              'content': harmlessCode,
            },
          ],
        });
        const WorkshopProposalWorkspaceStager().stage(
          session: session,
          responseText: response,
        );
        expect(session.status, WorkspaceSessionStatus.review);
        expect(session.workspace.read('lib/main.dart'), harmlessCode);
        expect(session.isApplyApproved, isFalse);
        expect(gateway.writeCalls, 0);
      });
    }

    test('does not enter review or materialize malformed output', () async {
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
      expect(session.isApplyApproved, isFalse);
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

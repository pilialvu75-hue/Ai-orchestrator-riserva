import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/airlab/workshop_airlab_capability_io.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';

void main() {
  group('WorkshopAirLabCapability', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('airlab-a4-');
    });

    tearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    test(
      'authorized opt-in task reaches AIrLab staging then VirtualWorkspace review only',
      () async {
        final requestedPaths = <String>[];
        final client = MockClient((request) async {
          requestedPaths.add(request.url.path);
          if (request.url.path == '/health') {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'status': 'ok',
                'service': 'airlab',
                'engine_id': 'mock-builder-a4',
              }),
              200,
            );
          }
          if (request.url.path == '/v1/capabilities') {
            return http.Response(
              jsonEncode(_capabilities()),
              200,
            );
          }
          if (request.url.path == '/v1/tasks') {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'request_id': 'airlab-a4-request',
                'status': 'ok',
                'engine_id': 'mock-builder-a4',
                'plan': <String>[
                  'prepare deterministic staged output',
                ],
                'operations': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'action': 'create',
                    'path': '.airlab/mock-result.txt',
                    'content': 'A4 deterministic result',
                  },
                ],
                'artifacts': <Map<String, dynamic>>[],
                'metadata': <String, dynamic>{
                  'mock': true,
                },
              }),
              200,
            );
          }
          return http.Response('{}', 404);
        });

        final capability = createWorkshopAirLabIoCapability(
          baseUri: Uri.parse('http://127.0.0.1:8788'),
          httpClient: client,
          enabled: true,
        );

        final gateway = _RecordingGateway(files: <String, String>{});
        final session = await _session(gateway);
        final stagingRoot = '${temp.path}/staging';

        final result = await capability.run(
          task: _task(),
          session: session,
          stagingRoot: stagingRoot,
          executionApprovalGranted: true,
          projectId: 'project-a4',
          target: 'android',
        );

        expect(result.availability.isAvailable, isTrue);
        expect(result.availability.resource.providerId, 'airlab');
        expect(result.promotedToReview, isTrue);
        expect(result.execution.requiresApproval, isTrue);
        expect(result.execution.metadata['stagingOnly'], isTrue);
        expect(result.execution.metadata['repositoryModified'], isFalse);

        expect(session.status, WorkspaceSessionStatus.review);
        expect(
          session.workspace.read('.airlab/mock-result.txt'),
          'A4 deterministic result',
        );

        // A4 stops at VirtualWorkspace review.
        expect(gateway.files, isEmpty);
        expect(gateway.writeCalls, 0);
        expect(gateway.deleteCalls, 0);
        expect(gateway.commitCalls, 0);
        expect(gateway.pushCalls, 0);
        expect(gateway.pullRequestCalls, 0);

        expect(
          await File('$stagingRoot/.airlab/mock-result.txt').readAsString(),
          'A4 deterministic result',
        );
        expect(
          requestedPaths.where((path) => path == '/v1/tasks').length,
          1,
        );

        // Only the pre-existing owner approval/apply sequence can mutate
        // the backing gateway.
        session.beginValidation();
        session.approveApply();
        await session.apply();

        expect(
          gateway.files['.airlab/mock-result.txt'],
          'A4 deterministic result',
        );
        expect(gateway.writeCalls, 1);
        expect(gateway.commitCalls, 0);
        expect(gateway.pushCalls, 0);
        expect(gateway.pullRequestCalls, 0);
      },
    );

    test('disabled capability is fail-closed and performs no HTTP calls',
        () async {
      var httpCalls = 0;
      final capability = createWorkshopAirLabIoCapability(
        baseUri: Uri.parse('http://127.0.0.1:8788'),
        httpClient: MockClient((request) async {
          httpCalls += 1;
          return http.Response('{}', 500);
        }),
      );

      final gateway = _RecordingGateway(files: <String, String>{});
      final session = await _session(gateway);

      final result = await capability.run(
        task: _task(),
        session: session,
        stagingRoot: '${temp.path}/staging',
        executionApprovalGranted: true,
      );

      expect(result.execution.status, WorkshopTaskStatus.failed);
      expect(result.execution.metadata['code'], 'airlab_disabled');
      expect(result.promotedToReview, isFalse);
      expect(httpCalls, 0);
      expect(session.status, WorkspaceSessionStatus.ready);
      expect(gateway.writeCalls, 0);
    });

    test('execution guard approval remains mandatory before AIrLab task call',
        () async {
      final requestedPaths = <String>[];
      final capability = createWorkshopAirLabIoCapability(
        baseUri: Uri.parse('http://127.0.0.1:8788'),
        httpClient: MockClient((request) async {
          requestedPaths.add(request.url.path);
          if (request.url.path == '/health') {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'status': 'ok',
                'service': 'airlab',
                'engine_id': 'mock-builder-a4',
              }),
              200,
            );
          }
          return http.Response('{}', 500);
        }),
        enabled: true,
      );

      final gateway = _RecordingGateway(files: <String, String>{});
      final session = await _session(gateway);

      final result = await capability.run(
        task: _task(),
        session: session,
        stagingRoot: '${temp.path}/staging',
      );

      expect(result.execution.status, WorkshopTaskStatus.waitingApproval);
      expect(result.promotedToReview, isFalse);
      expect(requestedPaths, <String>['/health']);
      expect(session.status, WorkspaceSessionStatus.ready);
      expect(gateway.writeCalls, 0);
    });

    test('remote AIrLab refuses offline execution without probing network',
        () async {
      var httpCalls = 0;
      final capability = createWorkshopAirLabIoCapability(
        baseUri: Uri.parse('https://airlab.example.invalid'),
        httpClient: MockClient((request) async {
          httpCalls += 1;
          return http.Response('{}', 500);
        }),
        enabled: true,
        networkRequired: true,
      );

      final gateway = _RecordingGateway(files: <String, String>{});
      final session = await _session(gateway);

      final result = await capability.run(
        task: _task(),
        session: session,
        stagingRoot: '${temp.path}/staging',
        networkAvailable: false,
        executionApprovalGranted: true,
      );

      expect(result.execution.status, WorkshopTaskStatus.failed);
      expect(result.execution.metadata['code'], 'network_unavailable');
      expect(httpCalls, 0);
      expect(session.status, WorkspaceSessionStatus.ready);
    });
  });
}

Map<String, dynamic> _capabilities() => <String, dynamic>{
      'service': 'airlab',
      'engine_id': 'mock-builder-a4',
      'engine_kind': 'mock',
      'hardware_required': false,
      'supports_streaming': false,
      'supports_tools': false,
      'max_context_tokens': null,
      'task_families': <String>[
        'software',
        'web',
        'cad',
        'manufacturing',
      ],
      'input_kinds': <String>[
        'text',
        'image',
        'drawing',
        'file',
        'measurement',
        'project',
      ],
      'artifact_formats': <String>[
        'airlab',
        'step',
        'scad',
        'dxf',
        'svg',
        '3mf',
        'stl',
        'gcode',
      ],
    };

WorkshopTaskContract _task() {
  return WorkshopTaskContract(
    id: 'airlab-a4-task',
    title: 'A4 capability task',
    objective: 'Create the deterministic AIrLab mock result.',
    kind: WorkshopTaskKind.codeGeneration,
    mode: WorkshopTaskMode.local,
    preferredResource: WorkshopTaskResource.local,
    instructions: const <String>[
      'Use only the assigned Cantiere staging root.',
    ],
    acceptanceCriteria: const <WorkshopTaskAcceptanceCriterion>[
      WorkshopTaskAcceptanceCriterion(
        id: 'staged-result',
        description: 'The deterministic result is staged for review.',
      ),
    ],
    fileScope: const WorkshopTaskFileScope(
      allowed: <String>['.airlab/mock-result.txt'],
    ),
    metadata: const <String, dynamic>{
      'airlabTaskFamily': 'software',
      'airlabTaskKind': 'software.build',
    },
  );
}

Future<WorkspaceSession> _session(_RecordingGateway gateway) async {
  final session = WorkspaceSession(
    request: const WorkshopRequest(
      id: 'workspace-a4',
      title: 'A4 workspace',
      instruction: 'Keep AIrLab output behind normal Cantiere approval.',
    ),
    gateway: gateway,
  );
  await session.initialize();
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
  Future<void> writeFile({
    required String path,
    required String content,
  }) async {
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

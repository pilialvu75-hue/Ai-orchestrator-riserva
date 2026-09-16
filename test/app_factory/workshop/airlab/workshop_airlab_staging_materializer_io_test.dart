import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import 'package:ai_orchestrator/app_factory/workshop/airlab/workshop_airlab_client.dart';
import 'package:ai_orchestrator/app_factory/workshop/airlab/workshop_airlab_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/airlab/workshop_airlab_staging_materializer.dart';
import 'package:ai_orchestrator/app_factory/workshop/airlab/workshop_airlab_staging_materializer_io.dart';
import 'package:ai_orchestrator/app_factory/workshop/airlab/workshop_airlab_task_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_execution_guard.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_executor.dart';

void main() {
  test('guarded AIrLab create is materialized only in assigned staging', () async {
    final sandbox = await Directory.systemTemp.createTemp('airlab-a2-');
    addTearDown(() async {
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    });

    final staging = Directory(p.join(sandbox.path, 'staging'));
    final realRepository = Directory(p.join(sandbox.path, 'real-repository'));
    await staging.create(recursive: true);
    await realRepository.create(recursive: true);
    final repositoryMarker = File(p.join(realRepository.path, 'protected.txt'));
    await repositoryMarker.writeAsString('unchanged');

    final executor = WorkshopAirLabTaskExecutor(
      client: WorkshopAirLabClient(
        baseUri: Uri.parse('http://127.0.0.1:8788'),
        httpClient: _successfulClient(
          operations: <Map<String, dynamic>>[
            <String, dynamic>{
              'action': 'create',
              'path': '.airlab/mock-result.txt',
              'content': 'mock',
            },
          ],
        ),
      ),
      stagingMaterializer: const WorkshopAirLabIoStagingMaterializer(),
    );

    final result = await executor.execute(
      task: WorkshopTaskContract(
        id: 'task-a2',
        title: 'A2 staging task',
        objective: 'Materialize the deterministic mock output',
        kind: WorkshopTaskKind.codeGeneration,
        fileScope: const WorkshopTaskFileScope(
          allowed: <String>['.airlab/mock-result.txt'],
        ),
      ),
      guardDecision: const WorkshopTaskExecutionGuardDecision.allowed(
        taskId: 'task-a2',
        resource: WorkshopTaskResource.local,
        providerId: 'airlab',
      ),
      context: WorkshopTaskExecutionContext(stagingRoot: staging.path),
    );

    final stagedFile = File(p.join(staging.path, '.airlab', 'mock-result.txt'));
    expect(result.status, WorkshopTaskStatus.waitingApproval);
    expect(result.requiresApproval, isTrue);
    expect(result.changedFiles, <String>['.airlab/mock-result.txt']);
    expect(result.metadata['stagingOnly'], isTrue);
    expect(result.metadata['repositoryModified'], isFalse);
    expect(result.metadata['promotionRequired'], isTrue);
    expect(result.checkpoint?.metadata['request_id'], 'airlab-request-a2');
    expect(result.checkpoint?.metadata['engine_id'], 'mock-builder-v2');
    expect(result.checkpoint?.metadata['task_id'], 'task-a2');
    expect(await stagedFile.readAsString(), 'mock');
    expect(await repositoryMarker.readAsString(), 'unchanged');
  });

  test('traversal and absolute operation paths are rejected before writes', () async {
    final sandbox = await Directory.systemTemp.createTemp('airlab-paths-');
    addTearDown(() async {
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    });

    const materializer = WorkshopAirLabIoStagingMaterializer();
    final staging = Directory(p.join(sandbox.path, 'staging'));
    await staging.create();

    for (final invalidPath in <String>['../escape.txt', '/absolute.txt', 'C:/escape.txt', 'a//b.txt']) {
      expect(
        () => materializer.materialize(
          stagingRoot: staging.path,
          operations: <WorkshopAirLabFileOperation>[
            WorkshopAirLabFileOperation(
              action: WorkshopAirLabFileOperationAction.create,
              path: invalidPath,
              content: 'blocked',
            ),
          ],
          fileScope: WorkshopTaskFileScope(allowed: <String>[invalidPath]),
        ),
        throwsA(isA<WorkshopAirLabStagingException>()),
      );
    }

    expect(await File(p.join(sandbox.path, 'escape.txt')).exists(), isFalse);
  });

  test('forbidden and read-only scope wins over allowed scope', () async {
    final sandbox = await Directory.systemTemp.createTemp('airlab-scope-');
    addTearDown(() async {
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    });

    const materializer = WorkshopAirLabIoStagingMaterializer();
    final staging = Directory(p.join(sandbox.path, 'staging'));
    await staging.create();

    Future<WorkshopAirLabStagingException> rejection(
      String path,
      WorkshopTaskFileScope scope,
    ) async {
      try {
        await materializer.materialize(
          stagingRoot: staging.path,
          operations: <WorkshopAirLabFileOperation>[
            WorkshopAirLabFileOperation(
              action: WorkshopAirLabFileOperationAction.create,
              path: path,
              content: 'blocked',
            ),
          ],
          fileScope: scope,
        );
      } on WorkshopAirLabStagingException catch (error) {
        return error;
      }
      fail('Expected AIrLab staging rejection for $path');
    }

    final forbidden = await rejection(
      '.airlab/secret.txt',
      const WorkshopTaskFileScope(
        allowed: <String>['.airlab/'],
        forbidden: <String>['.airlab/secret.txt'],
      ),
    );
    expect(forbidden.code, 'path_forbidden');

    final readOnly = await rejection(
      '.airlab/reference.txt',
      const WorkshopTaskFileScope(
        allowed: <String>['.airlab/'],
        readOnly: <String>['.airlab/reference.txt'],
      ),
    );
    expect(readOnly.code, 'path_read_only');
  });

  test('payload limits reject oversized AIrLab output before mutation', () async {
    final sandbox = await Directory.systemTemp.createTemp('airlab-limits-');
    addTearDown(() async {
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    });

    const materializer = WorkshopAirLabIoStagingMaterializer(
      limits: WorkshopAirLabStagingLimits(
        maxOperations: 2,
        maxPerFilePayloadBytes: 4,
        maxTotalPayloadBytes: 6,
      ),
    );
    final staging = Directory(p.join(sandbox.path, 'staging'));
    await staging.create();

    await expectLater(
      materializer.materialize(
        stagingRoot: staging.path,
        operations: const <WorkshopAirLabFileOperation>[
          WorkshopAirLabFileOperation(
            action: WorkshopAirLabFileOperationAction.create,
            path: 'too-large.txt',
            content: '12345',
          ),
        ],
        fileScope: const WorkshopTaskFileScope(
          allowed: <String>['too-large.txt'],
        ),
      ),
      throwsA(
        isA<WorkshopAirLabStagingException>().having(
          (error) => error.code,
          'code',
          'file_payload_limit_exceeded',
        ),
      ),
    );

    expect(await File(p.join(staging.path, 'too-large.txt')).exists(), isFalse);
  });

  test('symlink escape is rejected without touching the linked destination', () async {
    if (Platform.isWindows) return;

    final sandbox = await Directory.systemTemp.createTemp('airlab-symlink-');
    addTearDown(() async {
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    });

    final staging = Directory(p.join(sandbox.path, 'staging'));
    final outside = Directory(p.join(sandbox.path, 'outside'));
    await staging.create();
    await outside.create();
    await Link(p.join(staging.path, 'linked')).create(outside.path);

    const materializer = WorkshopAirLabIoStagingMaterializer();
    await expectLater(
      materializer.materialize(
        stagingRoot: staging.path,
        operations: const <WorkshopAirLabFileOperation>[
          WorkshopAirLabFileOperation(
            action: WorkshopAirLabFileOperationAction.create,
            path: 'linked/escape.txt',
            content: 'blocked',
          ),
        ],
        fileScope: const WorkshopTaskFileScope(
          allowed: <String>['linked/'],
        ),
      ),
      throwsA(
        isA<WorkshopAirLabStagingException>().having(
          (error) => error.code,
          'code',
          'symlink_escape',
        ),
      ),
    );

    expect(await File(p.join(outside.path, 'escape.txt')).exists(), isFalse);
  });
}

MockClient _successfulClient({
  required List<Map<String, dynamic>> operations,
}) {
  return MockClient((request) async {
    if (request.url.path == '/health') {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'status': 'ok',
          'service': 'airlab',
          'engine_id': 'mock-builder-v2',
        }),
        200,
      );
    }
    if (request.url.path == '/v1/capabilities') {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'service': 'airlab',
          'engine_id': 'mock-builder-v2',
          'engine_kind': 'mock',
          'hardware_required': false,
          'supports_streaming': false,
          'supports_tools': false,
          'max_context_tokens': null,
          'task_families': <String>['software', 'web', 'cad', 'manufacturing'],
          'input_kinds': <String>['text', 'image', 'drawing', 'file', 'measurement', 'project'],
          'artifact_formats': <String>['airlab', 'step', 'scad', 'dxf', 'svg', '3mf', 'stl', 'gcode'],
        }),
        200,
      );
    }
    if (request.url.path == '/v1/tasks') {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'request_id': 'airlab-request-a2',
          'status': 'ok',
          'engine_id': 'mock-builder-v2',
          'plan': <String>['prepare deterministic staging operation'],
          'operations': operations,
          'artifacts': <Map<String, dynamic>>[],
          'metadata': <String, dynamic>{'mock': true},
        }),
        200,
      );
    }
    return http.Response('{}', 404);
  });
}

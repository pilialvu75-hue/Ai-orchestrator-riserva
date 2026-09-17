import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ai_orchestrator/app_factory/workshop/airlab/workshop_airlab_client.dart';
import 'package:ai_orchestrator/app_factory/workshop/airlab/workshop_airlab_task_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_execution_guard.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_executor.dart';

void main() {
  test('Cantiere -> AIrLab mock -> Cantiere completes a software round trip', () async {
    final paths = <String>[];
    final client = WorkshopAirLabClient(
      baseUri: Uri.parse('http://127.0.0.1:8788'),
      httpClient: MockClient((request) async {
        paths.add(request.url.path);

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
          return http.Response(jsonEncode(_capabilities()), 200);
        }

        if (request.url.path == '/v1/tasks') {
          final payload = jsonDecode(request.body) as Map<String, dynamic>;
          expect(payload['task'], 'Create a notes application');
          expect(payload['task_family'], 'software');
          expect(payload['task_kind'], 'software.build');
          expect(payload['mode'], 'implement');
          expect(payload['project_id'], 'project-42');

          return http.Response(
            jsonEncode(_taskResponse(operations: const <Map<String, dynamic>>[])),
            200,
          );
        }

        return http.Response('{}', 404);
      }),
    );

    final executor = WorkshopAirLabTaskExecutor(client: client);
    final phases = <String>[];
    final result = await executor.execute(
      task: _task(
        kind: WorkshopTaskKind.codeGeneration,
        objective: 'Create a notes application',
      ),
      guardDecision: const WorkshopTaskExecutionGuardDecision.allowed(
        taskId: 'task-1',
        resource: WorkshopTaskResource.local,
        providerId: 'airlab',
      ),
      context: const WorkshopTaskExecutionContext(
        metadata: <String, dynamic>{'projectId': 'project-42'},
      ),
      onProgress: (progress) => phases.add(progress.phase),
    );

    expect(result.status, WorkshopTaskStatus.completed);
    expect(result.artifacts, <String>['project/project.airlab.json']);
    expect(result.metadata['requestId'], 'airlab-request-1');
    expect(result.metadata['engineId'], 'mock-builder-v2');
    expect(result.metadata['repositoryModified'], isFalse);
    expect(executor.isAvailable, isTrue);
    expect(
      phases,
      <String>['airlab_probe', 'airlab_execute', 'airlab_complete'],
    );
    expect(paths, <String>['/health', '/v1/capabilities', '/v1/tasks']);
  });

  test('blocked guard decision never reaches AIrLab', () async {
    var networkCalls = 0;
    final executor = WorkshopAirLabTaskExecutor(
      client: WorkshopAirLabClient(
        baseUri: Uri.parse('http://127.0.0.1:8788'),
        httpClient: MockClient((request) async {
          networkCalls += 1;
          return http.Response('{}', 500);
        }),
      ),
    );

    final result = await executor.execute(
      task: _task(
        kind: WorkshopTaskKind.planning,
        objective: 'Plan an application',
      ),
      guardDecision: const WorkshopTaskExecutionGuardDecision.blocked(
        taskId: 'task-1',
        message: 'approval required',
        blockReason: WorkshopTaskExecutionBlockReason.approvalRequired,
      ),
      context: const WorkshopTaskExecutionContext(),
    );

    expect(result.status, WorkshopTaskStatus.failed);
    expect(result.message, contains('Execution Guard'));
    expect(networkCalls, 0);
  });

  test('AIrLab unavailability is explicit and has no hidden fallback', () async {
    final executor = WorkshopAirLabTaskExecutor(
      client: WorkshopAirLabClient(
        baseUri: Uri.parse('http://127.0.0.1:8788'),
        httpClient: MockClient((request) async {
          return http.Response(
            jsonEncode(<String, dynamic>{'error': 'temporarily unavailable'}),
            503,
          );
        }),
      ),
    );

    final result = await executor.execute(
      task: _task(
        kind: WorkshopTaskKind.planning,
        objective: 'Plan an application',
      ),
      guardDecision: const WorkshopTaskExecutionGuardDecision.allowed(
        taskId: 'task-1',
        resource: WorkshopTaskResource.local,
        providerId: 'airlab',
      ),
      context: const WorkshopTaskExecutionContext(),
    );

    expect(result.status, WorkshopTaskStatus.failed);
    expect(result.metadata['availability'], 'unavailable');
    expect(executor.isAvailable, isFalse);
  });

  test('network loss after a successful probe is contained as a task failure', () async {
    final executor = WorkshopAirLabTaskExecutor(
      client: WorkshopAirLabClient(
        baseUri: Uri.parse('http://127.0.0.1:8788'),
        httpClient: MockClient((request) async {
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
          throw http.ClientException('connection lost after probe', request.url);
        }),
      ),
    );

    final result = await executor.execute(
      task: _task(
        kind: WorkshopTaskKind.planning,
        objective: 'Plan an application',
      ),
      guardDecision: const WorkshopTaskExecutionGuardDecision.allowed(
        taskId: 'task-1',
        resource: WorkshopTaskResource.local,
        providerId: 'airlab',
      ),
      context: const WorkshopTaskExecutionContext(),
    );

    expect(result.status, WorkshopTaskStatus.failed);
    expect(result.message, contains('AIrLab request failed'));
    expect(result.message, contains('connection lost after probe'));
    expect(result.metadata['code'], 'transport_unavailable');
    expect(executor.isAvailable, isTrue);
  });

  test('proposed operations fail closed without a staging materializer', () async {
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
    );

    final result = await executor.execute(
      task: _task(
        kind: WorkshopTaskKind.codeGeneration,
        objective: 'Create a notes application',
        fileScope: const WorkshopTaskFileScope(
          allowed: <String>['.airlab/mock-result.txt'],
        ),
      ),
      guardDecision: const WorkshopTaskExecutionGuardDecision.allowed(
        taskId: 'task-1',
        resource: WorkshopTaskResource.local,
        providerId: 'airlab',
      ),
      context: const WorkshopTaskExecutionContext(stagingRoot: '/controlled/staging'),
    );

    expect(result.status, WorkshopTaskStatus.failed);
    expect(result.metadata['code'], 'staging_materializer_unavailable');
    expect(result.metadata['requestId'], 'airlab-request-1');
  });

  test('mapper turns image + measurement CAD work into cad.reconstruct', () {
    final request = const WorkshopAirLabTaskRequestMapper().map(
      task: _task(
        kind: WorkshopTaskKind.build,
        objective: 'Reconstruct this broken bracket',
        metadata: <String, dynamic>{
          'airlabTaskFamily': 'cad',
          'airlabInputs': <Map<String, dynamic>>[
            <String, dynamic>{
              'kind': 'image',
              'reference': 'attachment:front',
            },
            <String, dynamic>{
              'kind': 'measurement',
              'reference': 'hole_spacing=63mm',
            },
          ],
          'airlabRequestedArtifacts': <String>['step', 'stl', '3mf'],
          'providerKey': 'must-not-leak',
        },
      ),
      context: const WorkshopTaskExecutionContext(),
    );

    expect(request.taskFamily, 'cad');
    expect(request.taskKind, 'cad.reconstruct');
    expect(request.inputs.length, 2);
    expect(request.requestedArtifacts, <String>['step', 'stl', '3mf']);
    expect(request.context, isEmpty);
    expect(jsonEncode(request.toJson()), isNot(contains('must-not-leak')));
  });

  test('manufacturing gcode request forwards only explicit printer profile', () {
    final request = const WorkshopAirLabTaskRequestMapper().map(
      task: _task(
        kind: WorkshopTaskKind.build,
        objective: 'Slice the validated model',
        metadata: <String, dynamic>{
          'airlabTaskFamily': 'manufacturing',
          'airlabRequestedArtifacts': <String>['gcode'],
          'airlabPrinterProfile': <String, dynamic>{
            'id': 'printer-profile-1',
            'nozzle_mm': 0.4,
          },
          'unrelatedSecret': 'do-not-forward',
        },
      ),
      context: const WorkshopTaskExecutionContext(),
    );

    expect(request.taskKind, 'manufacturing.slice');
    expect(request.context.keys, <String>['printer_profile']);
    expect(jsonEncode(request.toJson()), isNot(contains('do-not-forward')));
  });
}

MockClient _successfulClient({
  List<Map<String, dynamic>> operations = const <Map<String, dynamic>>[],
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
      return http.Response(jsonEncode(_capabilities()), 200);
    }
    if (request.url.path == '/v1/tasks') {
      return http.Response(jsonEncode(_taskResponse(operations: operations)), 200);
    }
    return http.Response('{}', 404);
  });
}

Map<String, dynamic> _taskResponse({
  required List<Map<String, dynamic>> operations,
}) =>
    <String, dynamic>{
      'request_id': 'airlab-request-1',
      'status': 'ok',
      'engine_id': 'mock-builder-v2',
      'plan': <String>[
        'classify software task as software.build',
        'inspect reusable modules and prior validated assets',
        'prepare implement work for target web',
        'validate the result before publication',
      ],
      if (operations.isNotEmpty) 'operations': operations,
      'artifacts': <Map<String, dynamic>>[
        <String, dynamic>{
          'format': 'airlab',
          'role': 'source',
          'path': 'project/project.airlab.json',
          'editable': true,
          'derived': false,
          'status': 'planned',
        },
      ],
      'metadata': <String, dynamic>{
        'mock': true,
        'task_family': 'software',
        'task_kind': 'software.build',
      },
    };

Map<String, dynamic> _capabilities() => <String, dynamic>{
      'service': 'airlab',
      'engine_id': 'mock-builder-v2',
      'engine_kind': 'mock',
      'hardware_required': false,
      'supports_streaming': false,
      'supports_tools': false,
      'max_context_tokens': null,
      'task_families': <String>['software', 'web', 'cad', 'manufacturing'],
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

WorkshopTaskContract _task({
  required WorkshopTaskKind kind,
  required String objective,
  Map<String, dynamic> metadata = const <String, dynamic>{},
  WorkshopTaskFileScope fileScope = const WorkshopTaskFileScope(),
}) {
  return WorkshopTaskContract(
    id: 'task-1',
    title: 'AIrLab task',
    objective: objective,
    kind: kind,
    metadata: metadata,
    fileScope: fileScope,
  );
}

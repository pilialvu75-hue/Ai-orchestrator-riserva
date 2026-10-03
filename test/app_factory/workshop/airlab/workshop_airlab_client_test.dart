import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ai_orchestrator/app_factory/workshop/airlab/workshop_airlab_client.dart';
import 'package:ai_orchestrator/app_factory/workshop/airlab/workshop_airlab_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/airlab/workshop_airlab_execution_correlation.dart';

const String _fingerprint =
    'db5c57fcf1b8861cc7469c311cf073c96d0d377fa2291ac09656f450f2304b2c';

void main() {
  test('probe reports AIrLab as available', () async {
    final client = WorkshopAirLabClient(
      baseUri: Uri.parse('http://127.0.0.1:8788'),
      httpClient: MockClient((request) async {
        expect(request.url.path, '/health');
        return http.Response(
          jsonEncode(<String, dynamic>{
            'status': 'ok',
            'service': 'airlab',
            'engine_id': 'mock-builder-v2',
          }),
          200,
        );
      }),
    );

    final probe = await client.probe();

    expect(probe.availability, WorkshopAirLabAvailability.available);
    expect(probe.engineId, 'mock-builder-v2');
  });

  test('probe preserves an explicit unavailable state', () async {
    final client = WorkshopAirLabClient(
      baseUri: Uri.parse('http://127.0.0.1:8788'),
      httpClient: MockClient((request) async {
        throw http.ClientException('connection refused', request.url);
      }),
    );

    final probe = await client.probe();

    expect(probe.availability, WorkshopAirLabAvailability.unavailable);
    expect(probe.reason, contains('connection refused'));
  });

  test('capabilities expose task families without assuming hardware', () async {
    final client = WorkshopAirLabClient(
      baseUri: Uri.parse('http://127.0.0.1:8788'),
      httpClient: MockClient((request) async {
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
            'artifact_formats': <String>['airlab', 'step', '3mf', 'stl', 'gcode'],
          }),
          200,
        );
      }),
    );

    final capabilities = await client.capabilities();

    expect(capabilities.hardwareRequired, isFalse);
    expect(capabilities.taskFamilies, contains('cad'));
    expect(capabilities.artifactFormats, contains('gcode'));
  });

  test('CAD task serializes image/measurement inputs and parses artifacts', () async {
    final client = WorkshopAirLabClient(
      baseUri: Uri.parse('http://127.0.0.1:8788'),
      authToken: 'test-token',
      httpClient: MockClient((request) async {
        expect(request.url.path, '/v1/tasks');
        expect(request.headers['authorization'], 'Bearer test-token');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['task_family'], 'cad');
        expect(body['task_kind'], 'cad.reconstruct');
        expect((body['inputs'] as List).length, 2);
        expect(body['requested_artifacts'], <String>['step', 'stl', '3mf']);
        expect(body.containsKey('execution_correlation'), isFalse);

        return http.Response(
          jsonEncode(<String, dynamic>{
            'request_id': 'request-1',
            'status': 'ok',
            'engine_id': 'mock-builder-v2',
            'plan': <String>['preserve editable master'],
            'operations': <dynamic>[],
            'artifacts': <Map<String, dynamic>>[
              <String, dynamic>{
                'format': 'airlab',
                'role': 'source',
                'path': 'project/project.airlab.json',
                'editable': true,
                'derived': false,
                'status': 'planned',
              },
              <String, dynamic>{
                'format': 'stl',
                'role': 'printable',
                'path': 'artifacts/output.stl',
                'editable': false,
                'derived': true,
                'status': 'planned',
              },
            ],
            'metadata': <String, dynamic>{'mock': true},
          }),
          200,
        );
      }),
    );

    final response = await client.submitTask(
      const WorkshopAirLabTaskRequest(
        task: 'Reconstruct this broken bracket',
        taskFamily: 'cad',
        taskKind: 'cad.reconstruct',
        inputs: <WorkshopAirLabTaskInput>[
          WorkshopAirLabTaskInput(kind: 'image', reference: 'attachment:front'),
          WorkshopAirLabTaskInput(kind: 'measurement', reference: 'hole_spacing=63mm'),
        ],
        requestedArtifacts: <String>['step', 'stl', '3mf'],
      ),
    );

    expect(response.requestId, 'request-1');
    expect(response.artifacts.first.editable, isTrue);
    expect(response.artifacts.last.format, 'stl');
  });

  test('task carries authoritative execution correlation to /v1/tasks', () async {
    final correlation = WorkshopAirLabExecutionCorrelation.create(
      projectId: 'project-abc',
      taskId: 'task-42',
      executionId: 'execution-123',
      attemptId: 'attempt-1',
      operationId: 'software.build',
      requestFingerprint: _fingerprint,
      checkpointId: 'checkpoint-1',
    );
    final client = WorkshopAirLabClient(
      baseUri: Uri.parse('http://127.0.0.1:8788'),
      authToken: 'test-token',
      httpClient: MockClient((request) async {
        expect(request.url.path, '/v1/tasks');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['project_id'], 'project-abc');
        expect(body['task_kind'], 'software.build');
        expect(body['execution_correlation'], correlation.toJson());

        return http.Response(
          jsonEncode(<String, dynamic>{
            'request_id': 'request-correlated',
            'status': 'ok',
            'engine_id': 'mock-builder-v2',
            'plan': <String>['validate correlated request'],
            'operations': <dynamic>[],
            'artifacts': <dynamic>[],
            'metadata': <String, dynamic>{'mock': true},
          }),
          200,
        );
      }),
    );

    final response = await client.submitTask(
      WorkshopAirLabTaskRequest(
        task: 'Build the correlated staging proof',
        projectId: 'project-abc',
        mode: 'implement',
        taskKind: 'software.build',
        executionCorrelation: correlation,
      ),
    );

    expect(response.requestId, 'request-correlated');
  });

  test('request rejects correlation project mismatch before HTTP', () {
    final correlation = WorkshopAirLabExecutionCorrelation.create(
      projectId: 'project-other',
      taskId: 'task-42',
      executionId: 'execution-123',
      attemptId: 'attempt-1',
      operationId: 'software.build',
      requestFingerprint: _fingerprint,
    );
    final request = WorkshopAirLabTaskRequest(
      task: 'Build the correlated staging proof',
      projectId: 'project-abc',
      taskKind: 'software.build',
      executionCorrelation: correlation,
    );

    expect(
      request.toJson,
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('project_id'),
        ),
      ),
    );
  });

  test('request rejects correlation operation mismatch before HTTP', () {
    final correlation = WorkshopAirLabExecutionCorrelation.create(
      projectId: 'project-abc',
      taskId: 'task-42',
      executionId: 'execution-123',
      attemptId: 'attempt-1',
      operationId: 'software.test',
      requestFingerprint: _fingerprint,
    );
    final request = WorkshopAirLabTaskRequest(
      task: 'Build the correlated staging proof',
      projectId: 'project-abc',
      taskKind: 'software.build',
      executionCorrelation: correlation,
    );

    expect(
      request.toJson,
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('operation_id'),
        ),
      ),
    );
  });
}

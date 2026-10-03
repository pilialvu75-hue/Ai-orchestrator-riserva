import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/airlab/workshop_airlab_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/airlab/workshop_airlab_execution_correlation.dart';

void main() {
  group('WorkshopAirLabTaskRequest execution_correlation transport', () {
    test('legacy request omits execution_correlation entirely', () {
      final payload = const WorkshopAirLabTaskRequest(
        task: 'Legacy task',
        projectId: 'project-abc',
        taskFamily: 'software',
        taskKind: 'software.build',
      ).toJson();

      expect(payload.containsKey('execution_correlation'), isFalse);
    });

    test('authoritative correlation is serialized with the task request', () {
      final correlation = _correlation();
      final payload = WorkshopAirLabTaskRequest(
        task: 'Durable task',
        projectId: 'project-abc',
        taskFamily: 'software',
        taskKind: 'software.build',
        executionCorrelation: correlation,
      ).toJson();

      expect(payload['execution_correlation'], correlation.toJson());
      final raw = payload['execution_correlation'] as Map<String, dynamic>;
      expect(raw['execution_id'], 'execution-123');
      expect(raw['attempt_id'], 'attempt-1');
      expect(
        raw['idempotency_key'],
        'airlab:v1:1637d6cf216f94593ac4e97bbb1bce0841553d46922a2ec754df8a8fe7eca701',
      );
    });

    test('project mismatch fails before HTTP serialization', () {
      final request = WorkshopAirLabTaskRequest(
        task: 'Durable task',
        projectId: 'different-project',
        taskFamily: 'software',
        taskKind: 'software.build',
        executionCorrelation: _correlation(),
      );

      expect(
        request.toJson,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('project_id'),
          ),
        ),
      );
    });

    test('operation mismatch fails before HTTP serialization', () {
      final request = WorkshopAirLabTaskRequest(
        task: 'Durable task',
        projectId: 'project-abc',
        taskFamily: 'software',
        taskKind: 'software.test',
        executionCorrelation: _correlation(),
      );

      expect(
        request.toJson,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('operation_id'),
          ),
        ),
      );
    });
  });
}

WorkshopAirLabExecutionCorrelation _correlation() {
  return WorkshopAirLabExecutionCorrelation.create(
    projectId: 'project-abc',
    taskId: 'task-42',
    executionId: 'execution-123',
    attemptId: 'attempt-1',
    operationId: 'software.build',
    requestFingerprint:
        'db5c57fcf1b8861cc7469c311cf073c96d0d377fa2291ac09656f450f2304b2c',
    checkpointId: 'checkpoint-1',
  );
}

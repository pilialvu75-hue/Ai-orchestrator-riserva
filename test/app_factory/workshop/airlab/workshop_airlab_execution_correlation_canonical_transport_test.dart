import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/airlab/workshop_airlab_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/airlab/workshop_airlab_execution_correlation.dart';

void main() {
  group('correlated AIrLab request canonical identities', () {
    test('rejects project_id with surrounding whitespace', () {
      final request = WorkshopAirLabTaskRequest(
        task: 'Durable task',
        projectId: ' project-abc ',
        taskKind: 'software.build',
        executionCorrelation: _correlation(),
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

    test('rejects task_kind with whitespace or case variants', () {
      final request = WorkshopAirLabTaskRequest(
        task: 'Durable task',
        projectId: 'project-abc',
        taskKind: ' Software.Build ',
        executionCorrelation: _correlation(),
      );

      expect(
        request.toJson,
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('task_kind'),
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

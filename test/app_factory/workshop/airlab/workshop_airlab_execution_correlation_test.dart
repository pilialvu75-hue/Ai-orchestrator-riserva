import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/airlab/workshop_airlab_execution_correlation.dart';

void main() {
  group('WorkshopAirLabExecutionCorrelation', () {
    test('matches the Python cross-language V1 idempotency vector', () {
      final key = workshopAirLabDeriveIdempotencyKey(
        projectId: 'project-abc',
        taskId: 'task-42',
        executionId: 'execution-123',
        operationId: 'software.build',
        requestFingerprint: _fingerprint,
      );

      expect(
        key,
        'airlab:v1:1637d6cf216f94593ac4e97bbb1bce0841553d46922a2ec754df8a8fe7eca701',
      );
    });

    test('new Cantiere attempt preserves the external-operation key', () {
      final first = _correlation();
      final second = first.forAttempt(
        attemptId: 'attempt-2',
        checkpointId: 'checkpoint-2',
      );

      expect(second.attemptId, isNot(first.attemptId));
      expect(second.checkpointId, isNot(first.checkpointId));
      expect(second.executionId, first.executionId);
      expect(second.idempotencyKey, first.idempotencyKey);
    });

    test('new execution operation or request fingerprint changes key', () {
      final baseline = _correlation();
      final differentExecution = _correlation(executionId: 'execution-124');
      final differentOperation = _correlation(operationId: 'software.test');
      final differentFingerprint = _correlation(
        requestFingerprint:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );

      expect(
        differentExecution.idempotencyKey,
        isNot(baseline.idempotencyKey),
      );
      expect(
        differentOperation.idempotencyKey,
        isNot(baseline.idempotencyKey),
      );
      expect(
        differentFingerprint.idempotencyKey,
        isNot(baseline.idempotencyKey),
      );
    });

    test('JSON round trip preserves authoritative correlation identity', () {
      final correlation = _correlation();
      final restored = WorkshopAirLabExecutionCorrelation.fromJson(
        correlation.toJson(),
      );

      expect(restored, correlation);
    });

    test('tampered idempotency key is rejected', () {
      final payload = Map<String, dynamic>.from(_correlation().toJson());
      payload['idempotency_key'] = 'airlab:v1:${'0' * 64}';

      expect(
        () => WorkshopAirLabExecutionCorrelation.fromJson(payload),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('idempotency_key'),
          ),
        ),
      );
    });

    test('invalid request fingerprint is rejected', () {
      expect(
        () => _correlation(requestFingerprint: 'not-a-sha256'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('WorkshopAirLab remote execution evidence', () {
    test('maps closed remote state vocabulary to bounded recovery actions', () {
      expect(
        workshopAirLabRecoveryActionFor(
          WorkshopAirLabRemoteExecutionState.accepted,
        ),
        WorkshopAirLabRecoveryAction.watch,
      );
      expect(
        workshopAirLabRecoveryActionFor(
          WorkshopAirLabRemoteExecutionState.running,
        ),
        WorkshopAirLabRecoveryAction.watch,
      );
      expect(
        workshopAirLabRecoveryActionFor(
          WorkshopAirLabRemoteExecutionState.succeeded,
        ),
        WorkshopAirLabRecoveryAction.reuseResult,
      );
      expect(
        workshopAirLabRecoveryActionFor(
          WorkshopAirLabRemoteExecutionState.retryableFailure,
        ),
        WorkshopAirLabRecoveryAction.retrySameKey,
      );
      expect(
        workshopAirLabRecoveryActionFor(
          WorkshopAirLabRemoteExecutionState.terminalFailure,
        ),
        WorkshopAirLabRecoveryAction.stop,
      );
      expect(
        workshopAirLabRecoveryActionFor(
          WorkshopAirLabRemoteExecutionState.cancelled,
        ),
        WorkshopAirLabRecoveryAction.stop,
      );
    });

    test('provider failover keeps the same external-operation key', () {
      final first = WorkshopAirLabRemoteExecutionEvidence(
        correlation: _correlation(),
        state: WorkshopAirLabRemoteExecutionState.retryableFailure,
        providerId: 'provider-a',
        remoteJobId: 'job-a',
        detailCode: 'timeout',
      );
      final second = WorkshopAirLabRemoteExecutionEvidence(
        correlation: first.correlation.forAttempt(attemptId: 'attempt-2'),
        state: WorkshopAirLabRemoteExecutionState.accepted,
        providerId: 'provider-b',
        remoteJobId: 'job-b',
      );

      expect(
        second.correlation.idempotencyKey,
        first.correlation.idempotencyKey,
      );
      expect(first.recoveryAction, WorkshopAirLabRecoveryAction.retrySameKey);
      expect(second.recoveryAction, WorkshopAirLabRecoveryAction.watch);
    });

    test('evidence JSON stays bounded to execution metadata', () {
      final evidence = WorkshopAirLabRemoteExecutionEvidence(
        correlation: _correlation(),
        state: WorkshopAirLabRemoteExecutionState.running,
        providerId: 'provider-a',
        remoteJobId: 'job-1',
      );

      final payload = evidence.toJson();
      expect(payload['state'], 'running');
      expect(payload['recovery_action'], 'watch');
      expect(payload.containsKey('prompt'), isFalse);
      expect(payload.containsKey('content'), isFalse);
      expect(payload.containsKey('secret'), isFalse);

      final restored = WorkshopAirLabRemoteExecutionEvidence.fromJson(payload);
      expect(restored.correlation, evidence.correlation);
      expect(restored.state, evidence.state);
      expect(restored.providerId, evidence.providerId);
      expect(restored.remoteJobId, evidence.remoteJobId);
    });
  });
}

const String _fingerprint =
    'db5c57fcf1b8861cc7469c311cf073c96d0d377fa2291ac09656f450f2304b2c';

WorkshopAirLabExecutionCorrelation _correlation({
  String projectId = 'project-abc',
  String taskId = 'task-42',
  String executionId = 'execution-123',
  String attemptId = 'attempt-1',
  String operationId = 'software.build',
  String requestFingerprint = _fingerprint,
  String? checkpointId = 'checkpoint-1',
}) {
  return WorkshopAirLabExecutionCorrelation.create(
    projectId: projectId,
    taskId: taskId,
    executionId: executionId,
    attemptId: attemptId,
    operationId: operationId,
    requestFingerprint: requestFingerprint,
    checkpointId: checkpointId,
  );
}

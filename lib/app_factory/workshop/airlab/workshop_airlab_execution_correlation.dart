import 'dart:convert';

import 'package:crypto/crypto.dart';

const int _executionCorrelationSchemaVersion = 1;
const String _idempotencyPrefix = 'airlab:v1:';
final RegExp _sha256Hex = RegExp(r'^[0-9a-f]{64}$');

String _requiredText(Object? value, String fieldName) {
  if (value is! String) {
    throw FormatException('$fieldName must be a string.');
  }
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw FormatException('$fieldName must be non-empty.');
  }
  if (normalized.length > 512) {
    throw FormatException('$fieldName is too long.');
  }
  return normalized;
}

String? _optionalText(Object? value, String fieldName) {
  if (value == null) return null;
  return _requiredText(value, fieldName);
}

String _requestFingerprint(Object? value) {
  final normalized = _requiredText(value, 'request_fingerprint').toLowerCase();
  if (!_sha256Hex.hasMatch(normalized)) {
    throw const FormatException(
      'request_fingerprint must be a lowercase SHA-256 hex digest.',
    );
  }
  return normalized;
}

/// Derives the language-neutral V1 idempotency key shared with Python AIrLab.
///
/// Attempt, checkpoint, provider and remote-job identities are intentionally
/// excluded so retries/failover of the same logical external operation reuse
/// the same key.
String workshopAirLabDeriveIdempotencyKey({
  required String projectId,
  required String taskId,
  required String executionId,
  required String operationId,
  required String requestFingerprint,
}) {
  final identity = <String, String>{
    // Keep this insertion order lexicographic. Dart jsonEncode preserves Map
    // insertion order, matching Python json.dumps(sort_keys=True, separators).
    'execution_id': _requiredText(executionId, 'execution_id'),
    'operation_id': _requiredText(operationId, 'operation_id'),
    'project_id': _requiredText(projectId, 'project_id'),
    'request_fingerprint': _requestFingerprint(requestFingerprint),
    'task_id': _requiredText(taskId, 'task_id'),
  };
  final canonical = jsonEncode(identity);
  final digest = sha256.convert(utf8.encode(canonical)).toString();
  return '$_idempotencyPrefix$digest';
}

/// Subordinate AIrLab identity for one Cantiere-owned external operation.
///
/// Cantiere remains authoritative for Project/Task/Execution/Attempt,
/// checkpoint/resume, Reviewer/validation and approval/apply. This contract is
/// execution evidence only; it does not create a second lifecycle.
final class WorkshopAirLabExecutionCorrelation {
  WorkshopAirLabExecutionCorrelation._({
    required this.projectId,
    required this.taskId,
    required this.executionId,
    required this.attemptId,
    required this.operationId,
    required this.requestFingerprint,
    required this.idempotencyKey,
    required this.checkpointId,
    required this.schemaVersion,
  });

  factory WorkshopAirLabExecutionCorrelation.create({
    required String projectId,
    required String taskId,
    required String executionId,
    required String attemptId,
    required String operationId,
    required String requestFingerprint,
    String? checkpointId,
  }) {
    final normalizedProjectId = _requiredText(projectId, 'project_id');
    final normalizedTaskId = _requiredText(taskId, 'task_id');
    final normalizedExecutionId = _requiredText(executionId, 'execution_id');
    final normalizedAttemptId = _requiredText(attemptId, 'attempt_id');
    final normalizedOperationId = _requiredText(operationId, 'operation_id');
    final normalizedFingerprint = _requestFingerprint(requestFingerprint);
    final normalizedCheckpointId = _optionalText(checkpointId, 'checkpoint_id');

    return WorkshopAirLabExecutionCorrelation._(
      projectId: normalizedProjectId,
      taskId: normalizedTaskId,
      executionId: normalizedExecutionId,
      attemptId: normalizedAttemptId,
      operationId: normalizedOperationId,
      requestFingerprint: normalizedFingerprint,
      idempotencyKey: workshopAirLabDeriveIdempotencyKey(
        projectId: normalizedProjectId,
        taskId: normalizedTaskId,
        executionId: normalizedExecutionId,
        operationId: normalizedOperationId,
        requestFingerprint: normalizedFingerprint,
      ),
      checkpointId: normalizedCheckpointId,
      schemaVersion: _executionCorrelationSchemaVersion,
    );
  }

  factory WorkshopAirLabExecutionCorrelation.fromJson(
    Map<String, dynamic> payload,
  ) {
    final schemaVersion = payload['schema_version'] ??
        _executionCorrelationSchemaVersion;
    if (schemaVersion != _executionCorrelationSchemaVersion) {
      throw FormatException(
        'Unsupported execution correlation schema_version: $schemaVersion.',
      );
    }

    final projectId = _requiredText(payload['project_id'], 'project_id');
    final taskId = _requiredText(payload['task_id'], 'task_id');
    final executionId = _requiredText(payload['execution_id'], 'execution_id');
    final attemptId = _requiredText(payload['attempt_id'], 'attempt_id');
    final operationId = _requiredText(payload['operation_id'], 'operation_id');
    final requestFingerprint = _requestFingerprint(
      payload['request_fingerprint'],
    );
    final checkpointId = _optionalText(
      payload['checkpoint_id'],
      'checkpoint_id',
    );
    final suppliedKey = _requiredText(
      payload['idempotency_key'],
      'idempotency_key',
    );
    final expectedKey = workshopAirLabDeriveIdempotencyKey(
      projectId: projectId,
      taskId: taskId,
      executionId: executionId,
      operationId: operationId,
      requestFingerprint: requestFingerprint,
    );
    if (suppliedKey != expectedKey) {
      throw const FormatException(
        'idempotency_key does not match the authoritative execution '
        'correlation identity.',
      );
    }

    return WorkshopAirLabExecutionCorrelation._(
      projectId: projectId,
      taskId: taskId,
      executionId: executionId,
      attemptId: attemptId,
      operationId: operationId,
      requestFingerprint: requestFingerprint,
      idempotencyKey: suppliedKey,
      checkpointId: checkpointId,
      schemaVersion: _executionCorrelationSchemaVersion,
    );
  }

  final String projectId;
  final String taskId;
  final String executionId;
  final String attemptId;
  final String operationId;
  final String requestFingerprint;
  final String idempotencyKey;
  final String? checkpointId;
  final int schemaVersion;

  WorkshopAirLabExecutionCorrelation forAttempt({
    required String attemptId,
    String? checkpointId,
  }) {
    return WorkshopAirLabExecutionCorrelation._(
      projectId: projectId,
      taskId: taskId,
      executionId: executionId,
      attemptId: _requiredText(attemptId, 'attempt_id'),
      operationId: operationId,
      requestFingerprint: requestFingerprint,
      idempotencyKey: idempotencyKey,
      checkpointId: _optionalText(checkpointId, 'checkpoint_id'),
      schemaVersion: schemaVersion,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schema_version': schemaVersion,
        'project_id': projectId,
        'task_id': taskId,
        'execution_id': executionId,
        'attempt_id': attemptId,
        'operation_id': operationId,
        'request_fingerprint': requestFingerprint,
        'idempotency_key': idempotencyKey,
        'checkpoint_id': checkpointId,
      };

  @override
  bool operator ==(Object other) {
    return other is WorkshopAirLabExecutionCorrelation &&
        other.schemaVersion == schemaVersion &&
        other.projectId == projectId &&
        other.taskId == taskId &&
        other.executionId == executionId &&
        other.attemptId == attemptId &&
        other.operationId == operationId &&
        other.requestFingerprint == requestFingerprint &&
        other.idempotencyKey == idempotencyKey &&
        other.checkpointId == checkpointId;
  }

  @override
  int get hashCode => Object.hash(
        schemaVersion,
        projectId,
        taskId,
        executionId,
        attemptId,
        operationId,
        requestFingerprint,
        idempotencyKey,
        checkpointId,
      );
}

enum WorkshopAirLabRemoteExecutionState {
  accepted('accepted'),
  running('running'),
  succeeded('succeeded'),
  retryableFailure('retryable_failure'),
  terminalFailure('terminal_failure'),
  cancelled('cancelled');

  const WorkshopAirLabRemoteExecutionState(this.jsonValue);

  final String jsonValue;

  static WorkshopAirLabRemoteExecutionState fromJson(Object? raw) {
    if (raw is! String) {
      throw const FormatException('Remote execution state must be a string.');
    }
    for (final state in values) {
      if (state.jsonValue == raw) return state;
    }
    throw FormatException('Unsupported remote execution state: $raw.');
  }
}

enum WorkshopAirLabRecoveryAction {
  watch('watch'),
  reuseResult('reuse_result'),
  retrySameKey('retry_same_key'),
  stop('stop');

  const WorkshopAirLabRecoveryAction(this.jsonValue);

  final String jsonValue;
}

WorkshopAirLabRecoveryAction workshopAirLabRecoveryActionFor(
  WorkshopAirLabRemoteExecutionState state,
) {
  switch (state) {
    case WorkshopAirLabRemoteExecutionState.accepted:
    case WorkshopAirLabRemoteExecutionState.running:
      return WorkshopAirLabRecoveryAction.watch;
    case WorkshopAirLabRemoteExecutionState.succeeded:
      return WorkshopAirLabRecoveryAction.reuseResult;
    case WorkshopAirLabRemoteExecutionState.retryableFailure:
      return WorkshopAirLabRecoveryAction.retrySameKey;
    case WorkshopAirLabRemoteExecutionState.terminalFailure:
    case WorkshopAirLabRemoteExecutionState.cancelled:
      return WorkshopAirLabRecoveryAction.stop;
  }
}

/// Provider-neutral evidence for a subordinate remote AIrLab/provider job.
final class WorkshopAirLabRemoteExecutionEvidence {
  WorkshopAirLabRemoteExecutionEvidence({
    required this.correlation,
    required this.state,
    String? providerId,
    String? remoteJobId,
    String? detailCode,
  })  : providerId = _optionalText(providerId, 'provider_id'),
        remoteJobId = _optionalText(remoteJobId, 'remote_job_id'),
        detailCode = _optionalText(detailCode, 'detail_code');

  final WorkshopAirLabExecutionCorrelation correlation;
  final WorkshopAirLabRemoteExecutionState state;
  final String? providerId;
  final String? remoteJobId;
  final String? detailCode;

  WorkshopAirLabRecoveryAction get recoveryAction =>
      workshopAirLabRecoveryActionFor(state);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'correlation': correlation.toJson(),
        'state': state.jsonValue,
        'provider_id': providerId,
        'remote_job_id': remoteJobId,
        'detail_code': detailCode,
        'recovery_action': recoveryAction.jsonValue,
      };

  factory WorkshopAirLabRemoteExecutionEvidence.fromJson(
    Map<String, dynamic> payload,
  ) {
    final correlationRaw = payload['correlation'];
    if (correlationRaw is! Map) {
      throw const FormatException(
        'Remote execution evidence correlation must be an object.',
      );
    }
    return WorkshopAirLabRemoteExecutionEvidence(
      correlation: WorkshopAirLabExecutionCorrelation.fromJson(
        Map<String, dynamic>.from(correlationRaw),
      ),
      state: WorkshopAirLabRemoteExecutionState.fromJson(payload['state']),
      providerId: payload['provider_id'] as String?,
      remoteJobId: payload['remote_job_id'] as String?,
      detailCode: payload['detail_code'] as String?,
    );
  }
}

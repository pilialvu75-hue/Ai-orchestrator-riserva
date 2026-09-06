import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:uuid/uuid.dart';

/// Lifecycle of one stable Workshop execution across one or more attempts.
///
/// Provider failover, model replacement and retry must not create a new
/// execution identity. They create a new [attemptId] while preserving the
/// execution, project, task, session and checkpoint identities.
enum WorkshopExecutionStatus {
  created,
  running,
  checkpointed,
  waitingApproval,
  completed,
  failed,
  cancelled,
}

/// Persistent identity and resumable operational state of one Workshop
/// execution.
///
/// [executionId] identifies the work being continued. [attemptId] identifies
/// the concrete executor/provider/model attempt currently carrying that work.
/// The Workshop task/checkpoint contracts remain the owners of workflow state;
/// this record only carries execution identity, runtime binding and usage data.
/// Prompts, source-code contents and credentials must never be stored here.
final class WorkshopExecution {
  const WorkshopExecution({
    required this.executionId,
    required this.attemptId,
    required this.projectId,
    required this.taskId,
    required this.sessionId,
    required this.resource,
    required this.status,
    required this.startedAt,
    required this.updatedAt,
    this.allocationId,
    this.executorId,
    this.providerId,
    this.modelId,
    this.accountId,
    this.checkpointId,
    this.resumePhase,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.estimatedCredits = 0,
    this.actualCost,
    this.metadata = const <String, dynamic>{},
  });

  final String executionId;
  final String attemptId;
  final String projectId;
  final String taskId;
  final String sessionId;
  final String? allocationId;
  final String? executorId;
  final WorkshopTaskResource resource;
  final String? providerId;
  final String? modelId;
  final String? accountId;
  final WorkshopExecutionStatus status;
  final DateTime startedAt;
  final DateTime updatedAt;
  final String? checkpointId;
  final String? resumePhase;
  final int inputTokens;
  final int outputTokens;
  final double estimatedCredits;
  final double? actualCost;
  final Map<String, dynamic> metadata;

  bool get isTerminal =>
      status == WorkshopExecutionStatus.completed ||
      status == WorkshopExecutionStatus.failed ||
      status == WorkshopExecutionStatus.cancelled;

  int get totalTokens => inputTokens + outputTokens;

  WorkshopExecution copyWith({
    String? attemptId,
    String? allocationId,
    String? executorId,
    WorkshopTaskResource? resource,
    String? providerId,
    String? modelId,
    String? accountId,
    WorkshopExecutionStatus? status,
    DateTime? updatedAt,
    String? checkpointId,
    String? resumePhase,
    int? inputTokens,
    int? outputTokens,
    double? estimatedCredits,
    double? actualCost,
    Map<String, dynamic>? metadata,
  }) {
    return WorkshopExecution(
      executionId: executionId,
      attemptId: attemptId ?? this.attemptId,
      projectId: projectId,
      taskId: taskId,
      sessionId: sessionId,
      allocationId: allocationId ?? this.allocationId,
      executorId: executorId ?? this.executorId,
      resource: resource ?? this.resource,
      providerId: providerId ?? this.providerId,
      modelId: modelId ?? this.modelId,
      accountId: accountId ?? this.accountId,
      status: status ?? this.status,
      startedAt: startedAt,
      updatedAt: (updatedAt ?? DateTime.now()).toUtc(),
      checkpointId: checkpointId ?? this.checkpointId,
      resumePhase: resumePhase ?? this.resumePhase,
      inputTokens: inputTokens ?? this.inputTokens,
      outputTokens: outputTokens ?? this.outputTokens,
      estimatedCredits: estimatedCredits ?? this.estimatedCredits,
      actualCost: actualCost ?? this.actualCost,
      metadata: Map<String, dynamic>.unmodifiable(
        metadata ?? this.metadata,
      ),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'executionId': executionId,
        'attemptId': attemptId,
        'projectId': projectId,
        'taskId': taskId,
        'sessionId': sessionId,
        'allocationId': allocationId,
        'executorId': executorId,
        'resource': resource.name,
        'providerId': providerId,
        'modelId': modelId,
        'accountId': accountId,
        'status': status.name,
        'startedAt': startedAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'checkpointId': checkpointId,
        'resumePhase': resumePhase,
        'inputTokens': inputTokens,
        'outputTokens': outputTokens,
        'estimatedCredits': estimatedCredits,
        'actualCost': actualCost,
        'metadata': metadata,
      };

  factory WorkshopExecution.fromJson(Map<String, dynamic> json) {
    final executionId = _requiredString(json, 'executionId');
    final attemptId = _optionalString(json['attemptId']) ?? executionId;
    final projectId = _requiredString(json, 'projectId');
    final taskId = _requiredString(json, 'taskId');
    final sessionId = _requiredString(json, 'sessionId');

    return WorkshopExecution(
      executionId: executionId,
      attemptId: attemptId,
      projectId: projectId,
      taskId: taskId,
      sessionId: sessionId,
      allocationId: _optionalString(json['allocationId']),
      executorId: _optionalString(json['executorId']),
      resource: _enumByName(
        WorkshopTaskResource.values,
        _requiredString(json, 'resource'),
        'resource',
      ),
      providerId: _optionalString(json['providerId']),
      modelId: _optionalString(json['modelId']),
      accountId: _optionalString(json['accountId']),
      status: _enumByName(
        WorkshopExecutionStatus.values,
        _requiredString(json, 'status'),
        'status',
      ),
      startedAt: _requiredDate(json, 'startedAt'),
      updatedAt: _requiredDate(json, 'updatedAt'),
      checkpointId: _optionalString(json['checkpointId']),
      resumePhase: _optionalString(json['resumePhase']),
      inputTokens: _integer(json['inputTokens']),
      outputTokens: _integer(json['outputTokens']),
      estimatedCredits: _number(json['estimatedCredits']),
      actualCost: json['actualCost'] is num
          ? (json['actualCost'] as num).toDouble()
          : null,
      metadata: json['metadata'] is Map
          ? Map<String, dynamic>.unmodifiable(
              Map<String, dynamic>.from(json['metadata'] as Map),
            )
          : const <String, dynamic>{},
    );
  }

  static String _requiredString(Map<String, dynamic> json, String key) {
    final value = _optionalString(json[key]);
    if (value == null) {
      throw FormatException('Workshop execution $key is missing.');
    }
    return value;
  }

  static DateTime _requiredDate(Map<String, dynamic> json, String key) {
    final raw = _requiredString(json, key);
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) {
      throw FormatException('Workshop execution $key is invalid.');
    }
    return parsed.toUtc();
  }

  static String? _optionalString(Object? value) {
    final normalized = value?.toString().trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  static T _enumByName<T extends Enum>(
    Iterable<T> values,
    String name,
    String field,
  ) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    throw FormatException('Unknown Workshop execution $field: $name');
  }

  static int _integer(Object? value) => value is num ? value.toInt() : 0;
  static double _number(Object? value) =>
      value is num ? value.toDouble() : 0;
}

/// Versioned index for stable Workshop execution identities and their current
/// runtime binding.
///
/// Workflow/project state remains owned by the Workshop task and checkpoint
/// contracts. This store only persists the execution identity needed to resume
/// that state across executor, provider, model or account replacement.
final class WorkshopExecutionStore {
  WorkshopExecutionStore({
    required PreferencesService preferences,
    Uuid uuid = const Uuid(),
  })  : _preferences = preferences,
        _uuid = uuid;

  static const String _storageKey = 'workshop.executions.v1';
  static const int _formatVersion = 1;

  final PreferencesService _preferences;
  final Uuid _uuid;

  Future<WorkshopExecution> create({
    required String projectId,
    required String taskId,
    required String sessionId,
    required WorkshopTaskResource resource,
    String? allocationId,
    String? executorId,
    String? providerId,
    String? modelId,
    String? accountId,
    double estimatedCredits = 0,
    Map<String, dynamic> metadata = const <String, dynamic>{},
  }) async {
    final now = DateTime.now().toUtc();
    final execution = WorkshopExecution(
      executionId: _uuid.v4(),
      attemptId: _uuid.v4(),
      projectId: _requireIdentity(projectId, 'projectId'),
      taskId: _requireIdentity(taskId, 'taskId'),
      sessionId: _requireIdentity(sessionId, 'sessionId'),
      allocationId: _normalized(allocationId),
      executorId: _normalized(executorId),
      resource: resource,
      providerId: _normalized(providerId),
      modelId: _normalized(modelId),
      accountId: _normalized(accountId),
      status: WorkshopExecutionStatus.created,
      startedAt: now,
      updatedAt: now,
      estimatedCredits: estimatedCredits < 0 ? 0 : estimatedCredits,
      metadata: Map<String, dynamic>.unmodifiable(metadata),
    );
    await save(execution);
    return execution;
  }

  /// Starts another concrete attempt of the same execution.
  ///
  /// This is the continuity boundary used for provider/model failover. Stable
  /// execution and checkpoint identities are preserved, while [attemptId] and
  /// the concrete runtime binding may change.
  Future<WorkshopExecution> beginNextAttempt({
    required WorkshopExecution execution,
    WorkshopTaskResource? resource,
    String? allocationId,
    String? executorId,
    String? providerId,
    String? modelId,
    String? accountId,
  }) async {
    final next = WorkshopExecution(
      executionId: execution.executionId,
      attemptId: _uuid.v4(),
      projectId: execution.projectId,
      taskId: execution.taskId,
      sessionId: execution.sessionId,
      allocationId: _normalized(allocationId) ?? execution.allocationId,
      executorId: _normalized(executorId) ?? execution.executorId,
      resource: resource ?? execution.resource,
      providerId: _normalized(providerId) ?? execution.providerId,
      modelId: _normalized(modelId) ?? execution.modelId,
      accountId: _normalized(accountId) ?? execution.accountId,
      status: WorkshopExecutionStatus.created,
      startedAt: execution.startedAt,
      updatedAt: DateTime.now().toUtc(),
      checkpointId: execution.checkpointId,
      resumePhase: execution.resumePhase,
      inputTokens: execution.inputTokens,
      outputTokens: execution.outputTokens,
      estimatedCredits: execution.estimatedCredits,
      actualCost: execution.actualCost,
      metadata: execution.metadata,
    );
    await save(next);
    return next;
  }

  Future<void> save(WorkshopExecution execution) async {
    final all = await _readAll();
    all[execution.executionId] = execution;
    await _writeAll(all);
  }

  Future<WorkshopExecution?> load(String executionId) async {
    final all = await _readAll();
    return all[_normalized(executionId)];
  }

  Future<List<WorkshopExecution>> loadAll() async {
    final all = await _readAll();
    final values = all.values.toList(growable: false)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List<WorkshopExecution>.unmodifiable(values);
  }

  Future<List<WorkshopExecution>> loadForTask(String taskId) async {
    final normalizedTaskId = _requireIdentity(taskId, 'taskId');
    final all = await loadAll();
    return List<WorkshopExecution>.unmodifiable(
      all.where((execution) => execution.taskId == normalizedTaskId),
    );
  }

  Future<WorkshopExecution?> latestResumableForTask(String taskId) async {
    final executions = await loadForTask(taskId);
    for (final execution in executions) {
      if (!execution.isTerminal &&
          (execution.checkpointId != null ||
              execution.status == WorkshopExecutionStatus.checkpointed ||
              execution.status == WorkshopExecutionStatus.waitingApproval)) {
        return execution;
      }
    }
    return null;
  }

  Future<void> remove(String executionId) async {
    final id = _normalized(executionId);
    if (id == null) return;
    final all = await _readAll();
    if (all.remove(id) != null) {
      await _writeAll(all);
    }
  }

  Future<Map<String, WorkshopExecution>> _readAll() async {
    final raw = _preferences.getString(_storageKey);
    if (raw == null || raw.trim().isEmpty) {
      return <String, WorkshopExecution>{};
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, WorkshopExecution>{};
      final root = Map<String, dynamic>.from(decoded);
      if (root['version'] != _formatVersion || root['items'] is! Map) {
        return <String, WorkshopExecution>{};
      }

      final result = <String, WorkshopExecution>{};
      final items = Map<String, dynamic>.from(root['items'] as Map);
      for (final entry in items.entries) {
        if (entry.value is! Map) continue;
        try {
          final execution = WorkshopExecution.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          );
          if (execution.executionId == entry.key) {
            result[entry.key] = execution;
          }
        } catch (_) {
          // One corrupt execution must not prevent recovery of the others.
        }
      }
      return result;
    } catch (_) {
      return <String, WorkshopExecution>{};
    }
  }

  Future<void> _writeAll(Map<String, WorkshopExecution> items) async {
    await _preferences.setString(
      _storageKey,
      jsonEncode(<String, dynamic>{
        'version': _formatVersion,
        'items': items.map(
          (key, value) => MapEntry<String, dynamic>(key, value.toJson()),
        ),
      }),
    );
  }

  String _requireIdentity(String value, String field) {
    final normalized = _normalized(value);
    if (normalized == null) {
      throw ArgumentError.value(value, field, '$field cannot be empty.');
    }
    return normalized;
  }

  String? _normalized(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}

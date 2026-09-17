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
/// execution attempt.
///
/// [executionId] identifies the logical work being continued. [attemptId]
/// identifies one concrete executor/provider/model attempt carrying that work.
/// [startedAt] is the stable start of the logical execution, while
/// [attemptStartedAt] records when this concrete attempt began.
///
/// Usage/cost fields belong to this attempt. Aggregate execution usage can be
/// obtained from [WorkshopExecutionStore.usageForExecution]. Prompts, source
/// contents and credentials must never be stored here.
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
    this.attemptStartedAt,
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

  /// Stable start time of the logical execution across all attempts.
  final DateTime startedAt;

  /// Start time of this concrete attempt. Legacy records fall back to
  /// [startedAt] without requiring a destructive migration.
  final DateTime? attemptStartedAt;

  final DateTime updatedAt;
  final String? checkpointId;
  final String? resumePhase;

  /// Usage/cost attributable to this concrete attempt.
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

  DateTime get effectiveAttemptStartedAt =>
      (attemptStartedAt ?? startedAt).toUtc();

  WorkshopExecution copyWith({
    String? attemptId,
    String? allocationId,
    String? executorId,
    WorkshopTaskResource? resource,
    String? providerId,
    String? modelId,
    String? accountId,
    WorkshopExecutionStatus? status,
    DateTime? attemptStartedAt,
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
      attemptStartedAt: attemptStartedAt ?? this.attemptStartedAt,
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
        'attemptStartedAt': attemptStartedAt?.toUtc().toIso8601String(),
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
      attemptStartedAt: _optionalDate(json['attemptStartedAt']),
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

  static DateTime? _optionalDate(Object? value) {
    final raw = _optionalString(value);
    if (raw == null) return null;
    return DateTime.tryParse(raw)?.toUtc();
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

/// Aggregate usage/cost across the retained attempts of one logical execution.
final class WorkshopExecutionUsageSummary {
  const WorkshopExecutionUsageSummary({
    required this.attemptCount,
    required this.inputTokens,
    required this.outputTokens,
    required this.estimatedCredits,
    required this.actualCost,
  });

  final int attemptCount;
  final int inputTokens;
  final int outputTokens;
  final double estimatedCredits;
  final double actualCost;

  int get totalTokens => inputTokens + outputTokens;
}

/// Versioned index for stable Workshop execution identities, current runtime
/// binding and a bounded per-attempt audit trail.
///
/// Workflow/project state remains owned by the Workshop task and checkpoint
/// contracts. The `items` section preserves the historical v1 current-record
/// shape. The optional `attempts` section extends that shape compatibly: an
/// existing v1 payload with only `items` is still loaded and its current record
/// is automatically treated as the first known attempt.
final class WorkshopExecutionStore {
  WorkshopExecutionStore({
    required PreferencesService preferences,
    Uuid uuid = const Uuid(),
    this.maxAttemptsPerExecution = 32,
  })  : assert(maxAttemptsPerExecution > 0),
        _preferences = preferences,
        _uuid = uuid;

  static const String _storageKey = 'workshop.executions.v1';
  static const int _formatVersion = 1;

  final PreferencesService _preferences;
  final Uuid _uuid;
  final int maxAttemptsPerExecution;

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
      attemptStartedAt: now,
      updatedAt: now,
      estimatedCredits: estimatedCredits < 0 ? 0 : estimatedCredits,
      metadata: Map<String, dynamic>.unmodifiable(metadata),
    );
    await save(execution);
    return execution;
  }

  /// Starts another concrete attempt of the same execution.
  ///
  /// The outgoing attempt is first persisted into the audit trail, then a new
  /// [attemptId] is created. Checkpoint identity and semantic resume phase are
  /// preserved, while provider/model/account binding may change. Usage/cost is
  /// reset because accounting belongs to the new attempt rather than being
  /// copied into it.
  Future<WorkshopExecution> beginNextAttempt({
    required WorkshopExecution execution,
    WorkshopTaskResource? resource,
    String? allocationId,
    String? executorId,
    String? providerId,
    String? modelId,
    String? accountId,
    double estimatedCredits = 0,
  }) async {
    await save(execution);

    final now = DateTime.now().toUtc();
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
      attemptStartedAt: now,
      updatedAt: now,
      checkpointId: execution.checkpointId,
      resumePhase: execution.resumePhase,
      estimatedCredits: estimatedCredits < 0 ? 0 : estimatedCredits,
      metadata: execution.metadata,
    );
    await save(next);
    return next;
  }

  /// Updates the current execution snapshot and the matching attempt snapshot.
  /// Saving the same [attemptId] updates that attempt in place; it never creates
  /// duplicate audit records for ordinary status/usage updates.
  Future<void> save(WorkshopExecution execution) async {
    final state = await _readState();
    state.current[execution.executionId] = execution;

    final attempts = state.attempts.putIfAbsent(
      execution.executionId,
      () => <String, WorkshopExecution>{},
    );
    attempts[execution.attemptId] = execution;
    _trimAttempts(attempts, preserveAttemptId: execution.attemptId);

    await _writeState(state);
  }

  Future<WorkshopExecution?> load(String executionId) async {
    final state = await _readState();
    return state.current[_normalized(executionId)];
  }

  Future<WorkshopExecution?> loadAttempt({
    required String executionId,
    required String attemptId,
  }) async {
    final normalizedExecutionId = _normalized(executionId);
    final normalizedAttemptId = _normalized(attemptId);
    if (normalizedExecutionId == null || normalizedAttemptId == null) {
      return null;
    }
    final state = await _readState();
    return state.attempts[normalizedExecutionId]?[normalizedAttemptId];
  }

  Future<List<WorkshopExecution>> loadAttempts(String executionId) async {
    final normalizedExecutionId = _requireIdentity(executionId, 'executionId');
    final state = await _readState();
    final attempts = state.attempts[normalizedExecutionId]?.values
            .toList(growable: false) ??
        <WorkshopExecution>[];
    attempts.sort((a, b) {
      final byStart = a.effectiveAttemptStartedAt
          .compareTo(b.effectiveAttemptStartedAt);
      if (byStart != 0) return byStart;
      return a.updatedAt.compareTo(b.updatedAt);
    });
    return List<WorkshopExecution>.unmodifiable(attempts);
  }

  Future<WorkshopExecutionUsageSummary> usageForExecution(
    String executionId,
  ) async {
    final attempts = await loadAttempts(executionId);
    var inputTokens = 0;
    var outputTokens = 0;
    var estimatedCredits = 0.0;
    var actualCost = 0.0;

    for (final attempt in attempts) {
      inputTokens += attempt.inputTokens;
      outputTokens += attempt.outputTokens;
      estimatedCredits += attempt.estimatedCredits;
      actualCost += attempt.actualCost ?? 0;
    }

    return WorkshopExecutionUsageSummary(
      attemptCount: attempts.length,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      estimatedCredits: estimatedCredits,
      actualCost: actualCost,
    );
  }

  Future<List<WorkshopExecution>> loadAll() async {
    final state = await _readState();
    final values = state.current.values.toList(growable: false)
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
    final state = await _readState();
    final removedCurrent = state.current.remove(id) != null;
    final removedAttempts = state.attempts.remove(id) != null;
    if (removedCurrent || removedAttempts) {
      await _writeState(state);
    }
  }

  Future<_WorkshopExecutionStoreState> _readState() async {
    final raw = _preferences.getString(_storageKey);
    if (raw == null || raw.trim().isEmpty) {
      return _WorkshopExecutionStoreState.empty();
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return _WorkshopExecutionStoreState.empty();
      final root = Map<String, dynamic>.from(decoded);
      if (root['version'] != _formatVersion || root['items'] is! Map) {
        return _WorkshopExecutionStoreState.empty();
      }

      final current = <String, WorkshopExecution>{};
      final items = Map<String, dynamic>.from(root['items'] as Map);
      for (final entry in items.entries) {
        final execution = _decodeExecution(entry.value);
        if (execution != null && execution.executionId == entry.key) {
          current[entry.key] = execution;
        }
      }

      final attempts = <String, Map<String, WorkshopExecution>>{};
      if (root['attempts'] is Map) {
        final rawAttempts = Map<String, dynamic>.from(root['attempts'] as Map);
        for (final executionEntry in rawAttempts.entries) {
          if (executionEntry.value is! Map) continue;
          final perExecution = <String, WorkshopExecution>{};
          final rawPerExecution =
              Map<String, dynamic>.from(executionEntry.value as Map);
          for (final attemptEntry in rawPerExecution.entries) {
            final attempt = _decodeExecution(attemptEntry.value);
            if (attempt != null &&
                attempt.executionId == executionEntry.key &&
                attempt.attemptId == attemptEntry.key) {
              perExecution[attemptEntry.key] = attempt;
            }
          }
          if (perExecution.isNotEmpty) {
            attempts[executionEntry.key] = perExecution;
          }
        }
      }

      // Backward-compatible migration for historical v1 payloads that contain
      // only `items`: retain the current attempt as the first audit snapshot.
      for (final execution in current.values) {
        attempts
            .putIfAbsent(
              execution.executionId,
              () => <String, WorkshopExecution>{},
            )
            .putIfAbsent(execution.attemptId, () => execution);
      }

      for (final entry in attempts.entries) {
        final currentAttemptId = current[entry.key]?.attemptId;
        _trimAttempts(
          entry.value,
          preserveAttemptId: currentAttemptId,
        );
      }

      return _WorkshopExecutionStoreState(
        current: current,
        attempts: attempts,
      );
    } catch (_) {
      return _WorkshopExecutionStoreState.empty();
    }
  }

  WorkshopExecution? _decodeExecution(Object? value) {
    if (value is! Map) return null;
    try {
      return WorkshopExecution.fromJson(
        Map<String, dynamic>.from(value),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeState(_WorkshopExecutionStoreState state) async {
    await _preferences.setString(
      _storageKey,
      jsonEncode(<String, dynamic>{
        'version': _formatVersion,
        'items': state.current.map(
          (key, value) => MapEntry<String, dynamic>(key, value.toJson()),
        ),
        'attempts': state.attempts.map(
          (executionId, attempts) => MapEntry<String, dynamic>(
            executionId,
            attempts.map(
              (attemptId, attempt) =>
                  MapEntry<String, dynamic>(attemptId, attempt.toJson()),
            ),
          ),
        ),
      }),
    );
  }

  void _trimAttempts(
    Map<String, WorkshopExecution> attempts, {
    String? preserveAttemptId,
  }) {
    if (attempts.length <= maxAttemptsPerExecution) return;

    final ordered = attempts.values.toList(growable: false)
      ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    for (final attempt in ordered) {
      if (attempts.length <= maxAttemptsPerExecution) break;
      if (attempt.attemptId == preserveAttemptId) continue;
      attempts.remove(attempt.attemptId);
    }
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

final class _WorkshopExecutionStoreState {
  _WorkshopExecutionStoreState({
    required this.current,
    required this.attempts,
  });

  factory _WorkshopExecutionStoreState.empty() => _WorkshopExecutionStoreState(
        current: <String, WorkshopExecution>{},
        attempts: <String, Map<String, WorkshopExecution>>{},
      );

  final Map<String, WorkshopExecution> current;
  final Map<String, Map<String, WorkshopExecution>> attempts;
}

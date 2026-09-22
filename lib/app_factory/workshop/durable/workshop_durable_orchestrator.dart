import 'dart:async';
import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/workshop_background_service.dart';

/// Durable scheduling states for long-running Cantiere work.
///
/// This is a scheduling overlay, not a second owner of Project/Execution.
/// Canonical project, workspace, review, validation, approval and apply state
/// remains in the existing Cantiere lifecycle.
enum WorkshopDurableState {
  created,
  planning,
  ready,
  running,
  waitingExternal,
  blocked,
  retrying,
  validating,
  completed,
  failed,
  cancelled,
}

enum WorkshopDurableFailureClass {
  networkError,
  rateLimit,
  providerUnavailable,
  buildError,
  codeError,
  invalidArtifact,
  validationFailed,
  timeout,
  policyBlocked,
  unknown,
}

enum WorkshopDurableWatchdogFindingType {
  staleRunning,
  expiredExternalWait,
  externalEventAvailable,
  blockedTooLong,
}

abstract final class WorkshopDurableEventTypes {
  static const projectCreated = 'project.created';
  static const taskStarted = 'task.started';
  static const taskCompleted = 'task.completed';
  static const taskFailed = 'task.failed';
  static const ciStarted = 'ci.started';
  static const ciCompleted = 'ci.completed';
  static const buildCompleted = 'build.completed';
  static const providerFailed = 'provider.failed';
  static const artifactReady = 'artifact.ready';
  static const validationFailed = 'validation.failed';
  static const validationPassed = 'validation.passed';
}

final class WorkshopDurableTransition {
  const WorkshopDurableTransition({
    required this.reason,
    required this.timestamp,
    required this.previousState,
    required this.nextState,
    required this.taskId,
    required this.projectId,
    required this.correlationId,
  });

  final String reason;
  final DateTime timestamp;
  final WorkshopDurableState previousState;
  final WorkshopDurableState nextState;
  final String taskId;
  final String projectId;
  final String correlationId;

  Map<String, Object?> toJson() => <String, Object?>{
        'reason': reason,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'previousState': previousState.name,
        'nextState': nextState.name,
        'taskId': taskId,
        'projectId': projectId,
        'correlationId': correlationId,
      };

  factory WorkshopDurableTransition.fromJson(Map<String, Object?> json) {
    return WorkshopDurableTransition(
      reason: _requiredString(json, 'reason'),
      timestamp: _requiredDate(json, 'timestamp'),
      previousState: _state(json['previousState']),
      nextState: _state(json['nextState']),
      taskId: _requiredString(json, 'taskId'),
      projectId: _requiredString(json, 'projectId'),
      correlationId: _requiredString(json, 'correlationId'),
    );
  }
}

final class WorkshopDurableRetryPolicy {
  const WorkshopDurableRetryPolicy({
    this.maxAttempts = 1,
    this.initialDelay = Duration.zero,
    this.retryableFailures = const <WorkshopDurableFailureClass>{
      WorkshopDurableFailureClass.networkError,
      WorkshopDurableFailureClass.rateLimit,
      WorkshopDurableFailureClass.providerUnavailable,
    },
  }) : assert(maxAttempts >= 1);

  final int maxAttempts;
  final Duration initialDelay;
  final Set<WorkshopDurableFailureClass> retryableFailures;

  bool allows(
    WorkshopDurableFailureClass failure,
    int attemptsStarted,
  ) {
    return attemptsStarted < maxAttempts && retryableFailures.contains(failure);
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'maxAttempts': maxAttempts,
        'initialDelayMs': initialDelay.inMilliseconds,
        'retryableFailures':
            retryableFailures.map((item) => item.name).toList(growable: false),
      };

  factory WorkshopDurableRetryPolicy.fromJson(Map<String, Object?> json) {
    final failures = <WorkshopDurableFailureClass>{};
    final raw = json['retryableFailures'];
    if (raw is List) {
      for (final value in raw) {
        for (final failure in WorkshopDurableFailureClass.values) {
          if (failure.name == value?.toString()) failures.add(failure);
        }
      }
    }
    final max = json['maxAttempts'] is num
        ? (json['maxAttempts'] as num).toInt()
        : 1;
    final delay = json['initialDelayMs'] is num
        ? (json['initialDelayMs'] as num).toInt()
        : 0;
    return WorkshopDurableRetryPolicy(
      maxAttempts: max < 1 ? 1 : max,
      initialDelay: Duration(milliseconds: delay < 0 ? 0 : delay),
      retryableFailures:
          Set<WorkshopDurableFailureClass>.unmodifiable(failures),
    );
  }
}

final class WorkshopDurableExternalWait {
  const WorkshopDurableExternalWait({
    required this.eventType,
    required this.startedAt,
    this.externalId,
    this.timeoutAt,
    this.successState = WorkshopDurableState.validating,
  });

  final String eventType;
  final String? externalId;
  final DateTime startedAt;
  final DateTime? timeoutAt;
  final WorkshopDurableState successState;

  bool matches(WorkshopDurableExternalEvent event) {
    if (event.type != eventType) return false;
    return externalId == null || externalId == event.externalId;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'eventType': eventType,
        if (externalId != null) 'externalId': externalId,
        'startedAt': startedAt.toUtc().toIso8601String(),
        if (timeoutAt != null)
          'timeoutAt': timeoutAt!.toUtc().toIso8601String(),
        'successState': successState.name,
      };

  factory WorkshopDurableExternalWait.fromJson(Map<String, Object?> json) {
    return WorkshopDurableExternalWait(
      eventType: _requiredString(json, 'eventType'),
      externalId: _optionalString(json['externalId']),
      startedAt: _requiredDate(json, 'startedAt'),
      timeoutAt: _optionalDate(json['timeoutAt']),
      successState: _state(json['successState']),
    );
  }
}

/// Closed technical event envelope. Raw prompts, source contents and secrets
/// must not be stored in this contract.
final class WorkshopDurableExternalEvent {
  const WorkshopDurableExternalEvent({
    required this.type,
    required this.projectId,
    required this.taskId,
    required this.correlationId,
    required this.idempotencyKey,
    required this.occurredAt,
    required this.success,
    this.externalId,
    this.failureClass,
    this.artifactIds = const <String>[],
  });

  final String type;
  final String projectId;
  final String taskId;
  final String correlationId;
  final String idempotencyKey;
  final DateTime occurredAt;
  final bool success;
  final String? externalId;
  final WorkshopDurableFailureClass? failureClass;
  final List<String> artifactIds;

  Map<String, Object?> toJson() => <String, Object?>{
        'type': type,
        'projectId': projectId,
        'taskId': taskId,
        'correlationId': correlationId,
        'idempotencyKey': idempotencyKey,
        'occurredAt': occurredAt.toUtc().toIso8601String(),
        'success': success,
        if (externalId != null) 'externalId': externalId,
        if (failureClass != null) 'failureClass': failureClass!.name,
        'artifactIds': artifactIds,
      };

  factory WorkshopDurableExternalEvent.fromJson(Map<String, Object?> json) {
    return WorkshopDurableExternalEvent(
      type: _requiredString(json, 'type'),
      projectId: _requiredString(json, 'projectId'),
      taskId: _requiredString(json, 'taskId'),
      correlationId: _requiredString(json, 'correlationId'),
      idempotencyKey: _requiredString(json, 'idempotencyKey'),
      occurredAt: _requiredDate(json, 'occurredAt'),
      success: json['success'] == true,
      externalId: _optionalString(json['externalId']),
      failureClass: _failureClass(json['failureClass']),
      artifactIds: _strings(json['artifactIds']),
    );
  }
}

final class WorkshopDurableTask {
  const WorkshopDurableTask({
    required this.taskId,
    required this.capability,
    required this.state,
    required this.updatedAt,
    this.dependencies = const <String>[],
    this.retryPolicy = const WorkshopDurableRetryPolicy(),
    this.timeout = const Duration(minutes: 30),
    this.completionCriterionIds = const <String>[],
    this.artifactIds = const <String>[],
    this.attemptsStarted = 0,
    this.retryNotBefore,
    this.externalWait,
    this.blockedReasonCode,
  });

  final String taskId;
  final List<String> dependencies;
  final String capability;
  final WorkshopDurableState state;
  final WorkshopDurableRetryPolicy retryPolicy;
  final Duration timeout;
  final List<String> completionCriterionIds;
  final List<String> artifactIds;
  final int attemptsStarted;
  final DateTime updatedAt;
  final DateTime? retryNotBefore;
  final WorkshopDurableExternalWait? externalWait;
  final String? blockedReasonCode;

  bool get isTerminal =>
      state == WorkshopDurableState.completed ||
      state == WorkshopDurableState.failed ||
      state == WorkshopDurableState.cancelled;

  WorkshopDurableTask copyWith({
    WorkshopDurableState? state,
    List<String>? artifactIds,
    int? attemptsStarted,
    DateTime? updatedAt,
    DateTime? retryNotBefore,
    bool clearRetryNotBefore = false,
    WorkshopDurableExternalWait? externalWait,
    bool clearExternalWait = false,
    String? blockedReasonCode,
    bool clearBlockedReason = false,
  }) {
    return WorkshopDurableTask(
      taskId: taskId,
      dependencies: dependencies,
      capability: capability,
      state: state ?? this.state,
      retryPolicy: retryPolicy,
      timeout: timeout,
      completionCriterionIds: completionCriterionIds,
      artifactIds: artifactIds ?? this.artifactIds,
      attemptsStarted: attemptsStarted ?? this.attemptsStarted,
      updatedAt: (updatedAt ?? DateTime.now()).toUtc(),
      retryNotBefore:
          clearRetryNotBefore ? null : (retryNotBefore ?? this.retryNotBefore),
      externalWait: clearExternalWait ? null : (externalWait ?? this.externalWait),
      blockedReasonCode:
          clearBlockedReason ? null : (blockedReasonCode ?? this.blockedReasonCode),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'taskId': taskId,
        'dependencies': dependencies,
        'capability': capability,
        'state': state.name,
        'retryPolicy': retryPolicy.toJson(),
        'timeoutMs': timeout.inMilliseconds,
        'completionCriterionIds': completionCriterionIds,
        'artifactIds': artifactIds,
        'attemptsStarted': attemptsStarted,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        if (retryNotBefore != null)
          'retryNotBefore': retryNotBefore!.toUtc().toIso8601String(),
        if (externalWait != null) 'externalWait': externalWait!.toJson(),
        if (blockedReasonCode != null)
          'blockedReasonCode': blockedReasonCode,
      };

  factory WorkshopDurableTask.fromJson(Map<String, Object?> json) {
    final retry = json['retryPolicy'];
    final wait = json['externalWait'];
    final timeoutMs =
        json['timeoutMs'] is num ? (json['timeoutMs'] as num).toInt() : 1800000;
    return WorkshopDurableTask(
      taskId: _requiredString(json, 'taskId'),
      dependencies: _strings(json['dependencies']),
      capability: _requiredString(json, 'capability'),
      state: _state(json['state']),
      retryPolicy: retry is Map
          ? WorkshopDurableRetryPolicy.fromJson(
              Map<String, Object?>.from(retry),
            )
          : const WorkshopDurableRetryPolicy(),
      timeout: Duration(milliseconds: timeoutMs <= 0 ? 1800000 : timeoutMs),
      completionCriterionIds: _strings(json['completionCriterionIds']),
      artifactIds: _strings(json['artifactIds']),
      attemptsStarted: json['attemptsStarted'] is num
          ? (json['attemptsStarted'] as num).toInt()
          : 0,
      updatedAt: _requiredDate(json, 'updatedAt'),
      retryNotBefore: _optionalDate(json['retryNotBefore']),
      externalWait: wait is Map
          ? WorkshopDurableExternalWait.fromJson(
              Map<String, Object?>.from(wait),
            )
          : null,
      blockedReasonCode: _optionalString(json['blockedReasonCode']),
    );
  }
}

final class WorkshopDurableProjectSnapshot {
  const WorkshopDurableProjectSnapshot({
    required this.projectId,
    required this.correlationId,
    required this.state,
    required this.createdAt,
    required this.updatedAt,
    required this.tasks,
    this.transitions = const <WorkshopDurableTransition>[],
    this.receivedEventKeys = const <String>{},
    this.processedIdempotencyKeys = const <String>{},
    this.claimedOperationKeys = const <String>{},
    this.events = const <WorkshopDurableExternalEvent>[],
    this.version = 1,
  });

  final int version;
  final String projectId;
  final String correlationId;
  final WorkshopDurableState state;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Map<String, WorkshopDurableTask> tasks;
  final List<WorkshopDurableTransition> transitions;
  final Set<String> receivedEventKeys;
  final Set<String> processedIdempotencyKeys;
  final Set<String> claimedOperationKeys;
  final List<WorkshopDurableExternalEvent> events;

  WorkshopDurableProjectSnapshot copyWith({
    WorkshopDurableState? state,
    DateTime? updatedAt,
    Map<String, WorkshopDurableTask>? tasks,
    List<WorkshopDurableTransition>? transitions,
    Set<String>? receivedEventKeys,
    Set<String>? processedIdempotencyKeys,
    Set<String>? claimedOperationKeys,
    List<WorkshopDurableExternalEvent>? events,
  }) {
    return WorkshopDurableProjectSnapshot(
      version: version,
      projectId: projectId,
      correlationId: correlationId,
      state: state ?? this.state,
      createdAt: createdAt,
      updatedAt: (updatedAt ?? DateTime.now()).toUtc(),
      tasks: Map<String, WorkshopDurableTask>.unmodifiable(tasks ?? this.tasks),
      transitions: List<WorkshopDurableTransition>.unmodifiable(
        transitions ?? this.transitions,
      ),
      receivedEventKeys: Set<String>.unmodifiable(
        receivedEventKeys ?? this.receivedEventKeys,
      ),
      processedIdempotencyKeys: Set<String>.unmodifiable(
        processedIdempotencyKeys ?? this.processedIdempotencyKeys,
      ),
      claimedOperationKeys: Set<String>.unmodifiable(
        claimedOperationKeys ?? this.claimedOperationKeys,
      ),
      events: List<WorkshopDurableExternalEvent>.unmodifiable(
        events ?? this.events,
      ),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'version': version,
        'projectId': projectId,
        'correlationId': correlationId,
        'state': state.name,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'tasks': <String, Object?>{
          for (final entry in tasks.entries) entry.key: entry.value.toJson(),
        },
        'transitions':
            transitions.map((item) => item.toJson()).toList(growable: false),
        'receivedEventKeys': receivedEventKeys.toList(growable: false),
        'processedIdempotencyKeys':
            processedIdempotencyKeys.toList(growable: false),
        'claimedOperationKeys': claimedOperationKeys.toList(growable: false),
        'events': events.map((item) => item.toJson()).toList(growable: false),
      };

  factory WorkshopDurableProjectSnapshot.fromJson(Map<String, Object?> json) {
    final rawTasks = json['tasks'];
    if (rawTasks is! Map) {
      throw const FormatException('Durable project tasks are missing.');
    }
    final tasks = <String, WorkshopDurableTask>{};
    for (final entry in rawTasks.entries) {
      if (entry.value is! Map) continue;
      final task = WorkshopDurableTask.fromJson(
        Map<String, Object?>.from(entry.value as Map),
      );
      if (task.taskId == entry.key.toString()) tasks[task.taskId] = task;
    }

    final transitions = <WorkshopDurableTransition>[];
    final rawTransitions = json['transitions'];
    if (rawTransitions is List) {
      for (final item in rawTransitions) {
        if (item is Map) {
          transitions.add(
            WorkshopDurableTransition.fromJson(
              Map<String, Object?>.from(item),
            ),
          );
        }
      }
    }

    final events = <WorkshopDurableExternalEvent>[];
    final rawEvents = json['events'];
    if (rawEvents is List) {
      for (final item in rawEvents) {
        if (item is Map) {
          events.add(
            WorkshopDurableExternalEvent.fromJson(
              Map<String, Object?>.from(item),
            ),
          );
        }
      }
    }

    final snapshot = WorkshopDurableProjectSnapshot(
      version: json['version'] is num ? (json['version'] as num).toInt() : 1,
      projectId: _requiredString(json, 'projectId'),
      correlationId: _requiredString(json, 'correlationId'),
      state: _state(json['state']),
      createdAt: _requiredDate(json, 'createdAt'),
      updatedAt: _requiredDate(json, 'updatedAt'),
      tasks: Map<String, WorkshopDurableTask>.unmodifiable(tasks),
      transitions: List<WorkshopDurableTransition>.unmodifiable(transitions),
      receivedEventKeys:
          Set<String>.unmodifiable(_strings(json['receivedEventKeys'])),
      processedIdempotencyKeys:
          Set<String>.unmodifiable(_strings(json['processedIdempotencyKeys'])),
      claimedOperationKeys:
          Set<String>.unmodifiable(_strings(json['claimedOperationKeys'])),
      events: List<WorkshopDurableExternalEvent>.unmodifiable(events),
    );
    _validateTaskGraph(snapshot.tasks);
    return snapshot;
  }
}

abstract interface class WorkshopDurableOrchestrationStore {
  Future<void> save(WorkshopDurableProjectSnapshot snapshot);
  Future<WorkshopDurableProjectSnapshot?> load(String projectId);
  Future<List<WorkshopDurableProjectSnapshot>> loadAll();
  Future<void> remove(String projectId);
}

/// Persistence adapter over the existing WorkshopCheckpointStore.
///
/// It creates no new database and stores only scheduler/correlation metadata.
final class WorkshopCheckpointDurableOrchestrationStore
    implements WorkshopDurableOrchestrationStore {
  WorkshopCheckpointDurableOrchestrationStore({
    required WorkshopCheckpointStore checkpointStore,
  }) : _checkpointStore = checkpointStore;

  static const _jobPrefix = 'workshop-durable-orchestrator:v1:';
  static const _payloadPrefix = 'workshop-durable-orchestrator-state-v1:';

  final WorkshopCheckpointStore _checkpointStore;

  @override
  Future<void> save(WorkshopDurableProjectSnapshot snapshot) async {
    String? activeTask;
    for (final task in snapshot.tasks.values) {
      if (!task.isTerminal) {
        activeTask = task.taskId;
        break;
      }
    }
    final completed = snapshot.tasks.values
        .where((task) => task.state == WorkshopDurableState.completed)
        .length;
    await _checkpointStore.save(
      WorkshopBackgroundCheckpoint(
        jobId: _jobPrefix + snapshot.projectId,
        requestId: snapshot.correlationId,
        status: _backgroundStatus(snapshot.state),
        updatedAt: snapshot.updatedAt,
        projectId: snapshot.projectId,
        taskId: activeTask,
        completedTasks: completed,
        totalTasks: snapshot.tasks.length,
        message: _payloadPrefix + jsonEncode(snapshot.toJson()),
      ),
    );
  }

  @override
  Future<WorkshopDurableProjectSnapshot?> load(String projectId) async {
    final normalized = projectId.trim();
    if (normalized.isEmpty) return null;
    final checkpoint = await _checkpointStore.load(_jobPrefix + normalized);
    if (checkpoint == null) return null;
    return _decode(checkpoint);
  }

  @override
  Future<List<WorkshopDurableProjectSnapshot>> loadAll() async {
    final checkpoints = await _checkpointStore.loadAll();
    final result = <WorkshopDurableProjectSnapshot>[];
    for (final checkpoint in checkpoints) {
      if (!checkpoint.jobId.startsWith(_jobPrefix)) continue;
      try {
        final value = _decode(checkpoint);
        if (value != null) result.add(value);
      } on FormatException {
        // One damaged orchestration overlay must not hide other projects.
      }
    }
    result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List<WorkshopDurableProjectSnapshot>.unmodifiable(result);
  }

  @override
  Future<void> remove(String projectId) {
    final normalized = projectId.trim();
    if (normalized.isEmpty) return Future<void>.value();
    return _checkpointStore.remove(_jobPrefix + normalized);
  }

  WorkshopDurableProjectSnapshot? _decode(
    WorkshopBackgroundCheckpoint checkpoint,
  ) {
    final message = checkpoint.message;
    if (message == null || !message.startsWith(_payloadPrefix)) return null;
    final decoded = jsonDecode(message.substring(_payloadPrefix.length));
    if (decoded is! Map) {
      throw const FormatException('Invalid durable orchestrator payload.');
    }
    final snapshot = WorkshopDurableProjectSnapshot.fromJson(
      Map<String, Object?>.from(decoded),
    );
    if (checkpoint.projectId != null &&
        checkpoint.projectId != snapshot.projectId) {
      throw const FormatException('Durable project identity mismatch.');
    }
    return snapshot;
  }

  static WorkshopBackgroundStatus _backgroundStatus(
    WorkshopDurableState state,
  ) {
    switch (state) {
      case WorkshopDurableState.completed:
        return WorkshopBackgroundStatus.completed;
      case WorkshopDurableState.failed:
        return WorkshopBackgroundStatus.failed;
      case WorkshopDurableState.cancelled:
        return WorkshopBackgroundStatus.cancelled;
      case WorkshopDurableState.running:
      case WorkshopDurableState.retrying:
      case WorkshopDurableState.validating:
        return WorkshopBackgroundStatus.running;
      case WorkshopDurableState.blocked:
      case WorkshopDurableState.waitingExternal:
        return WorkshopBackgroundStatus.paused;
      case WorkshopDurableState.created:
      case WorkshopDurableState.planning:
      case WorkshopDurableState.ready:
        return WorkshopBackgroundStatus.idle;
    }
  }
}

final class WorkshopDurableEventResult {
  const WorkshopDurableEventResult({
    required this.snapshot,
    required this.duplicate,
    required this.matchedTask,
  });

  final WorkshopDurableProjectSnapshot snapshot;
  final bool duplicate;
  final bool matchedTask;
}

final class WorkshopDurableWatchdogFinding {
  const WorkshopDurableWatchdogFinding({
    required this.type,
    required this.projectId,
    required this.taskId,
    required this.reason,
  });

  final WorkshopDurableWatchdogFindingType type;
  final String projectId;
  final String taskId;
  final String reason;
}

final class WorkshopDurableOrchestrator {
  WorkshopDurableOrchestrator({
    required WorkshopDurableOrchestrationStore store,
    DateTime Function()? clock,
  })  : _store = store,
        _clock = clock ?? DateTime.now;

  final WorkshopDurableOrchestrationStore _store;
  final DateTime Function() _clock;
  Future<void> _mutationTail = Future<void>.value();

  Future<WorkshopDurableProjectSnapshot> createProject({
    required String projectId,
    required String correlationId,
    required List<WorkshopDurableTask> tasks,
  }) {
    return _serialize(() async {
      final id = _identity(projectId, 'projectId');
      final correlation = _identity(correlationId, 'correlationId');
      final existing = await _store.load(id);
      if (existing != null) {
        if (existing.correlationId != correlation) {
          throw StateError(
            'Durable project id collision: existing correlation does not match.',
          );
        }
        return existing;
      }

      final byId = <String, WorkshopDurableTask>{};
      for (final task in tasks) {
        final taskId = _identity(task.taskId, 'taskId');
        if (byId.containsKey(taskId)) {
          throw StateError('Duplicate durable task id: ' + taskId);
        }
        byId[taskId] = task;
      }
      _validateTaskGraph(byId);

      final now = _clock().toUtc();
      var snapshot = WorkshopDurableProjectSnapshot(
        projectId: id,
        correlationId: correlation,
        state: WorkshopDurableState.created,
        createdAt: now,
        updatedAt: now,
        tasks: Map<String, WorkshopDurableTask>.unmodifiable(byId),
      );
      snapshot = _projectTransition(
        snapshot,
        WorkshopDurableState.planning,
        WorkshopDurableEventTypes.projectCreated,
        now,
      );
      await _store.save(snapshot);
      return snapshot;
    });
  }

  Future<WorkshopDurableProjectSnapshot?> loadProject(String projectId) {
    return _store.load(projectId);
  }

  Future<WorkshopDurableProjectSnapshot> markProjectReady(
    String projectId, {
    String reason = 'planning.completed',
  }) {
    return _mutate(projectId, (snapshot, now) {
      var next = snapshot;
      for (final task in snapshot.tasks.values) {
        if (task.state == WorkshopDurableState.created ||
            task.state == WorkshopDurableState.planning) {
          next = _taskTransition(
            next,
            task,
            WorkshopDurableState.ready,
            reason,
            now,
          );
        }
      }
      return _projectTransition(
        next,
        WorkshopDurableState.ready,
        reason,
        now,
      );
    });
  }

  Future<bool> claimOperation({
    required String projectId,
    required String idempotencyKey,
  }) {
    return _serialize(() async {
      final key = _identity(idempotencyKey, 'idempotencyKey');
      final snapshot = await _requiredProject(projectId);
      if (snapshot.claimedOperationKeys.contains(key)) return false;
      await _store.save(
        snapshot.copyWith(
          claimedOperationKeys: <String>{
            ...snapshot.claimedOperationKeys,
            key,
          },
          updatedAt: _clock().toUtc(),
        ),
      );
      return true;
    });
  }

  Future<WorkshopDurableProjectSnapshot> startTask({
    required String projectId,
    required String taskId,
    String reason = WorkshopDurableEventTypes.taskStarted,
    String? operationIdempotencyKey,
  }) {
    return _mutate(projectId, (snapshot, now) {
      if (operationIdempotencyKey != null &&
          snapshot.claimedOperationKeys.contains(operationIdempotencyKey)) {
        return snapshot;
      }
      final task = _requiredTask(snapshot, taskId);
      if (!_dependenciesCompleted(snapshot, task)) {
        throw StateError('Task dependencies are incomplete: ' + task.taskId);
      }
      if (task.isTerminal ||
          task.state == WorkshopDurableState.waitingExternal) {
        throw StateError('Task cannot start from state: ' + task.state.name);
      }
      if (task.retryNotBefore != null &&
          now.isBefore(task.retryNotBefore!.toUtc())) {
        throw StateError('Task retry delay has not elapsed: ' + task.taskId);
      }

      var next = _taskTransition(
        snapshot,
        task.copyWith(
          attemptsStarted: task.attemptsStarted + 1,
          clearRetryNotBefore: true,
          clearExternalWait: true,
          clearBlockedReason: true,
          updatedAt: now,
        ),
        WorkshopDurableState.running,
        reason,
        now,
      );
      if (operationIdempotencyKey != null) {
        next = next.copyWith(
          claimedOperationKeys: <String>{
            ...next.claimedOperationKeys,
            _identity(operationIdempotencyKey, 'operationIdempotencyKey'),
          },
        );
      }
      return _projectTransition(
        next,
        WorkshopDurableState.running,
        reason,
        now,
      );
    });
  }

  /// Atomically starts a task and persists its external wait before the
  /// caller performs the remote side effect.
  ///
  /// This closes the crash window between "task started" and
  /// "WAITING_EXTERNAL persisted". The operation idempotency key is committed
  /// in the same store mutation.
  Future<WorkshopDurableProjectSnapshot> startTaskAndWaitForExternal({
    required String projectId,
    required String taskId,
    required String operationIdempotencyKey,
    required WorkshopDurableExternalWait wait,
    String startReason = WorkshopDurableEventTypes.taskStarted,
    String waitReason = 'external.wait.persisted_before_side_effect',
  }) {
    return _mutate(projectId, (snapshot, now) {
      final operationKey =
          _identity(operationIdempotencyKey, 'operationIdempotencyKey');
      final task = _requiredTask(snapshot, taskId);

      if (snapshot.claimedOperationKeys.contains(operationKey)) {
        if (task.state == WorkshopDurableState.waitingExternal &&
            task.externalWait != null) {
          return snapshot;
        }
        throw StateError(
          'Durable operation key is already claimed without an external wait.',
        );
      }

      if (!_dependenciesCompleted(snapshot, task)) {
        throw StateError('Task dependencies are incomplete: ' + task.taskId);
      }
      if (task.state != WorkshopDurableState.ready &&
          task.state != WorkshopDurableState.retrying) {
        throw StateError(
          'Atomic external start requires READY/RETRYING task, got ' +
              task.state.name,
        );
      }
      if (task.retryNotBefore != null &&
          now.isBefore(task.retryNotBefore!.toUtc())) {
        throw StateError('Task retry delay has not elapsed: ' + task.taskId);
      }

      var next = _taskTransition(
        snapshot,
        task.copyWith(
          attemptsStarted: task.attemptsStarted + 1,
          clearRetryNotBefore: true,
          clearExternalWait: true,
          clearBlockedReason: true,
          updatedAt: now,
        ),
        WorkshopDurableState.running,
        startReason,
        now,
      );

      next = next.copyWith(
        claimedOperationKeys: <String>{
          ...next.claimedOperationKeys,
          operationKey,
        },
        updatedAt: now,
      );

      final runningTask = next.tasks[task.taskId]!;
      next = _taskTransition(
        next,
        runningTask.copyWith(
          externalWait: wait,
          updatedAt: now,
        ),
        WorkshopDurableState.waitingExternal,
        waitReason,
        now,
      );

      return _recomputeProjectState(next, now, waitReason);
    });
  }

  Future<WorkshopDurableProjectSnapshot> completeTask({
    required String projectId,
    required String taskId,
    String reason = WorkshopDurableEventTypes.taskCompleted,
    List<String> artifactIds = const <String>[],
  }) {
    return _mutate(projectId, (snapshot, now) {
      final task = _requiredTask(snapshot, taskId);
      final artifacts = <String>{...task.artifactIds, ...artifactIds}.toList()
        ..sort();
      final next = _taskTransition(
        snapshot,
        task.copyWith(artifactIds: artifacts, updatedAt: now),
        WorkshopDurableState.completed,
        reason,
        now,
      );
      return _recomputeProjectState(next, now, reason);
    });
  }

  Future<WorkshopDurableProjectSnapshot> waitForExternal({
    required String projectId,
    required String taskId,
    required WorkshopDurableExternalWait wait,
    String reason = 'external.wait.started',
  }) {
    return _mutate(projectId, (snapshot, now) {
      final task = _requiredTask(snapshot, taskId);
      if (task.state != WorkshopDurableState.running &&
          task.state != WorkshopDurableState.validating) {
        throw StateError('External wait requires a running/validating task.');
      }
      final next = _taskTransition(
        snapshot,
        task.copyWith(externalWait: wait, updatedAt: now),
        WorkshopDurableState.waitingExternal,
        reason,
        now,
      );
      return _recomputeProjectState(next, now, reason);
    });
  }

  Future<WorkshopDurableProjectSnapshot> beginValidation({
    required String projectId,
    required String taskId,
    String reason = 'validation.started',
  }) {
    return _mutate(projectId, (snapshot, now) {
      final task = _requiredTask(snapshot, taskId);
      final next = _taskTransition(
        snapshot,
        task.copyWith(clearExternalWait: true, updatedAt: now),
        WorkshopDurableState.validating,
        reason,
        now,
      );
      return _recomputeProjectState(next, now, reason);
    });
  }

  Future<WorkshopDurableProjectSnapshot> validationPassed({
    required String projectId,
    required String taskId,
    List<String> artifactIds = const <String>[],
  }) {
    return completeTask(
      projectId: projectId,
      taskId: taskId,
      reason: WorkshopDurableEventTypes.validationPassed,
      artifactIds: artifactIds,
    );
  }

  Future<WorkshopDurableProjectSnapshot> failTask({
    required String projectId,
    required String taskId,
    required WorkshopDurableFailureClass failureClass,
    String reason = WorkshopDurableEventTypes.taskFailed,
  }) {
    return _mutate(projectId, (snapshot, now) {
      final task = _requiredTask(snapshot, taskId);
      return _applyFailure(snapshot, task, failureClass, reason, now);
    });
  }

  Future<WorkshopDurableProjectSnapshot> cancelTask({
    required String projectId,
    required String taskId,
    String reason = 'task.cancelled',
  }) {
    return _mutate(projectId, (snapshot, now) {
      final task = _requiredTask(snapshot, taskId);
      if (task.state == WorkshopDurableState.cancelled) return snapshot;
      if (task.state == WorkshopDurableState.completed ||
          task.state == WorkshopDurableState.failed) {
        throw StateError(
          'Terminal task cannot be cancelled from state: ' + task.state.name,
        );
      }

      final next = _taskTransition(
        snapshot,
        task.copyWith(
          clearExternalWait: true,
          clearRetryNotBefore: true,
          clearBlockedReason: true,
          updatedAt: now,
        ),
        WorkshopDurableState.cancelled,
        reason,
        now,
      );
      return _recomputeProjectState(next, now, reason);
    });
  }

  Future<WorkshopDurableProjectSnapshot> cancelProject(
    String projectId, {
    String reason = 'project.cancelled',
  }) {
    return _mutate(projectId, (snapshot, now) {
      if (snapshot.state == WorkshopDurableState.cancelled) return snapshot;
      if (snapshot.state == WorkshopDurableState.completed ||
          snapshot.state == WorkshopDurableState.failed) {
        throw StateError(
          'Terminal project cannot be cancelled from state: ' +
              snapshot.state.name,
        );
      }

      var next = snapshot;
      for (final task in snapshot.tasks.values) {
        if (task.isTerminal) continue;
        next = _taskTransition(
          next,
          task.copyWith(
            clearExternalWait: true,
            clearRetryNotBefore: true,
            clearBlockedReason: true,
            updatedAt: now,
          ),
          WorkshopDurableState.cancelled,
          reason,
          now,
        );
      }
      return _projectTransition(
        next,
        WorkshopDurableState.cancelled,
        reason,
        now,
      );
    });
  }

  Future<WorkshopDurableProjectSnapshot> blockForHuman({
    required String projectId,
    required String taskId,
    required String reasonCode,
  }) {
    return _mutate(projectId, (snapshot, now) {
      final task = _requiredTask(snapshot, taskId);
      final next = _taskTransition(
        snapshot,
        task.copyWith(
          blockedReasonCode: _identity(reasonCode, 'reasonCode'),
          updatedAt: now,
        ),
        WorkshopDurableState.blocked,
        'human_gate:' + reasonCode,
        now,
      );
      return _recomputeProjectState(next, now, 'human_gate:' + reasonCode);
    });
  }

  Future<WorkshopDurableProjectSnapshot> resumeFromHumanGate({
    required String projectId,
    required String taskId,
  }) {
    return _mutate(projectId, (snapshot, now) {
      final task = _requiredTask(snapshot, taskId);
      if (task.state != WorkshopDurableState.blocked) {
        throw StateError('Task is not blocked: ' + task.taskId);
      }
      final next = _taskTransition(
        snapshot,
        task.copyWith(clearBlockedReason: true, updatedAt: now),
        WorkshopDurableState.ready,
        'human_gate.resolved',
        now,
      );
      return _recomputeProjectState(next, now, 'human_gate.resolved');
    });
  }

  Future<WorkshopDurableEventResult> handleExternalEvent(
    WorkshopDurableExternalEvent event, {
    WorkshopDurableExternalWait? nextWait,
  }) {
    return _serialize(() async {
      final snapshot = await _requiredProject(event.projectId);
      final key = _identity(event.idempotencyKey, 'idempotencyKey');
      if (snapshot.processedIdempotencyKeys.contains(key)) {
        return WorkshopDurableEventResult(
          snapshot: snapshot,
          duplicate: true,
          matchedTask: false,
        );
      }
      if (event.correlationId != snapshot.correlationId) {
        throw StateError('External event correlation does not match project.');
      }

      final now = _clock().toUtc();
      final wasAlreadyReceived = snapshot.receivedEventKeys.contains(key);
      var next = wasAlreadyReceived
          ? snapshot
          : snapshot.copyWith(
              receivedEventKeys: <String>{
                ...snapshot.receivedEventKeys,
                key,
              },
              events: <WorkshopDurableExternalEvent>[
                ...snapshot.events,
                event,
              ],
              updatedAt: now,
            );

      final task = next.tasks[event.taskId];
      final wait = task?.externalWait;
      var matched = false;

      if (task != null &&
          task.state == WorkshopDurableState.waitingExternal &&
          wait != null &&
          wait.matches(event)) {
        matched = true;
        next = next.copyWith(
          processedIdempotencyKeys: <String>{
            ...next.processedIdempotencyKeys,
            key,
          },
          updatedAt: now,
        );
        if (event.success) {
          final artifacts =
              <String>{...task.artifactIds, ...event.artifactIds}.toList()
                ..sort();
          var advancedTask = task.copyWith(
            artifactIds: artifacts,
            clearExternalWait: true,
            updatedAt: now,
          );
          final advancedState = nextWait == null
              ? wait.successState
              : WorkshopDurableState.waitingExternal;
          if (nextWait != null) {
            advancedTask = advancedTask.copyWith(
              externalWait: nextWait,
              updatedAt: now,
            );
          }
          next = _taskTransition(
            next,
            advancedTask,
            advancedState,
            event.type,
            now,
          );
          next = _recomputeProjectState(next, now, event.type);
        } else {
          next = _applyFailure(
            next,
            task,
            event.failureClass ?? WorkshopDurableFailureClass.unknown,
            event.type,
            now,
          );
        }
      }

      await _store.save(next);
      return WorkshopDurableEventResult(
        snapshot: next,
        duplicate: wasAlreadyReceived,
        matchedTask: matched,
      );
    });
  }

  Future<List<WorkshopDurableTask>> runnableTasks(String projectId) async {
    final snapshot = await _requiredProject(projectId);
    final now = _clock().toUtc();
    final result = snapshot.tasks.values.where((task) {
      final eligible = task.state == WorkshopDurableState.ready ||
          task.state == WorkshopDurableState.retrying;
      if (!eligible) return false;
      if (task.retryNotBefore != null &&
          now.isBefore(task.retryNotBefore!.toUtc())) {
        return false;
      }
      return _dependenciesCompleted(snapshot, task);
    }).toList(growable: false)
      ..sort((a, b) => a.taskId.compareTo(b.taskId));
    return List<WorkshopDurableTask>.unmodifiable(result);
  }

  Future<List<WorkshopDurableWatchdogFinding>> watchdogScan(
    String projectId, {
    List<WorkshopDurableExternalEvent> observedEvents =
        const <WorkshopDurableExternalEvent>[],
    Duration blockedThreshold = const Duration(hours: 24),
  }) async {
    final snapshot = await _requiredProject(projectId);
    final now = _clock().toUtc();
    final findings = <WorkshopDurableWatchdogFinding>[];

    for (final task in snapshot.tasks.values) {
      if (task.state == WorkshopDurableState.running &&
          now.difference(task.updatedAt.toUtc()) > task.timeout) {
        findings.add(
          WorkshopDurableWatchdogFinding(
            type: WorkshopDurableWatchdogFindingType.staleRunning,
            projectId: snapshot.projectId,
            taskId: task.taskId,
            reason: 'running_timeout',
          ),
        );
      }

      if (task.state == WorkshopDurableState.waitingExternal &&
          task.externalWait != null) {
        final wait = task.externalWait!;
        if (wait.timeoutAt != null && now.isAfter(wait.timeoutAt!.toUtc())) {
          findings.add(
            WorkshopDurableWatchdogFinding(
              type: WorkshopDurableWatchdogFindingType.expiredExternalWait,
              projectId: snapshot.projectId,
              taskId: task.taskId,
              reason: 'external_wait_timeout',
            ),
          );
        }
        for (final event in observedEvents) {
          if (!snapshot.processedIdempotencyKeys.contains(event.idempotencyKey) &&
              event.projectId == snapshot.projectId &&
              event.taskId == task.taskId &&
              event.correlationId == snapshot.correlationId &&
              wait.matches(event)) {
            findings.add(
              WorkshopDurableWatchdogFinding(
                type:
                    WorkshopDurableWatchdogFindingType.externalEventAvailable,
                projectId: snapshot.projectId,
                taskId: task.taskId,
                reason: event.type,
              ),
            );
            break;
          }
        }
      }

      if (task.state == WorkshopDurableState.blocked &&
          now.difference(task.updatedAt.toUtc()) > blockedThreshold) {
        findings.add(
          WorkshopDurableWatchdogFinding(
            type: WorkshopDurableWatchdogFindingType.blockedTooLong,
            projectId: snapshot.projectId,
            taskId: task.taskId,
            reason: task.blockedReasonCode ?? 'blocked',
          ),
        );
      }
    }

    return List<WorkshopDurableWatchdogFinding>.unmodifiable(findings);
  }

  Future<List<WorkshopDurableEventResult>> reconcileObservedEvents(
    Iterable<WorkshopDurableExternalEvent> events,
  ) async {
    final result = <WorkshopDurableEventResult>[];
    for (final event in events) {
      result.add(await handleExternalEvent(event));
    }
    return List<WorkshopDurableEventResult>.unmodifiable(result);
  }

  Future<WorkshopDurableProjectSnapshot> _mutate(
    String projectId,
    WorkshopDurableProjectSnapshot Function(
      WorkshopDurableProjectSnapshot snapshot,
      DateTime now,
    ) mutation,
  ) {
    return _serialize(() async {
      final snapshot = await _requiredProject(projectId);
      final next = mutation(snapshot, _clock().toUtc());
      await _store.save(next);
      return next;
    });
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _mutationTail = _mutationTail.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<WorkshopDurableProjectSnapshot> _requiredProject(
    String projectId,
  ) async {
    final id = _identity(projectId, 'projectId');
    final snapshot = await _store.load(id);
    if (snapshot == null) {
      throw StateError('Unknown durable project: ' + id);
    }
    return snapshot;
  }

  static WorkshopDurableTask _requiredTask(
    WorkshopDurableProjectSnapshot snapshot,
    String taskId,
  ) {
    final id = _identity(taskId, 'taskId');
    final task = snapshot.tasks[id];
    if (task == null) throw StateError('Unknown durable task: ' + id);
    return task;
  }

  static bool _dependenciesCompleted(
    WorkshopDurableProjectSnapshot snapshot,
    WorkshopDurableTask task,
  ) {
    for (final id in task.dependencies) {
      if (snapshot.tasks[id]?.state != WorkshopDurableState.completed) {
        return false;
      }
    }
    return true;
  }

  WorkshopDurableProjectSnapshot _applyFailure(
    WorkshopDurableProjectSnapshot snapshot,
    WorkshopDurableTask task,
    WorkshopDurableFailureClass failure,
    String reason,
    DateTime now,
  ) {
    if (task.retryPolicy.allows(failure, task.attemptsStarted)) {
      final next = _taskTransition(
        snapshot,
        task.copyWith(
          retryNotBefore: now.add(task.retryPolicy.initialDelay),
          clearExternalWait: true,
          updatedAt: now,
        ),
        WorkshopDurableState.retrying,
        reason + ':' + failure.name,
        now,
      );
      return _recomputeProjectState(next, now, reason);
    }

    final next = _taskTransition(
      snapshot,
      task.copyWith(clearExternalWait: true, updatedAt: now),
      WorkshopDurableState.failed,
      reason + ':' + failure.name,
      now,
    );
    return _recomputeProjectState(next, now, reason);
  }

  static WorkshopDurableProjectSnapshot _taskTransition(
    WorkshopDurableProjectSnapshot snapshot,
    WorkshopDurableTask task,
    WorkshopDurableState nextState,
    String reason,
    DateTime now,
  ) {
    final previous = snapshot.tasks[task.taskId]?.state ?? task.state;
    final tasks = <String, WorkshopDurableTask>{...snapshot.tasks};
    tasks[task.taskId] = task.copyWith(state: nextState, updatedAt: now);
    if (previous == nextState) {
      return snapshot.copyWith(tasks: tasks, updatedAt: now);
    }
    return snapshot.copyWith(
      tasks: tasks,
      transitions: <WorkshopDurableTransition>[
        ...snapshot.transitions,
        WorkshopDurableTransition(
          reason: reason,
          timestamp: now,
          previousState: previous,
          nextState: nextState,
          taskId: task.taskId,
          projectId: snapshot.projectId,
          correlationId: snapshot.correlationId,
        ),
      ],
      updatedAt: now,
    );
  }

  static WorkshopDurableProjectSnapshot _projectTransition(
    WorkshopDurableProjectSnapshot snapshot,
    WorkshopDurableState nextState,
    String reason,
    DateTime now,
  ) {
    if (snapshot.state == nextState) return snapshot;
    return snapshot.copyWith(
      state: nextState,
      transitions: <WorkshopDurableTransition>[
        ...snapshot.transitions,
        WorkshopDurableTransition(
          reason: reason,
          timestamp: now,
          previousState: snapshot.state,
          nextState: nextState,
          taskId: '@project',
          projectId: snapshot.projectId,
          correlationId: snapshot.correlationId,
        ),
      ],
      updatedAt: now,
    );
  }

  static WorkshopDurableProjectSnapshot _recomputeProjectState(
    WorkshopDurableProjectSnapshot snapshot,
    DateTime now,
    String reason,
  ) {
    final tasks = snapshot.tasks.values;
    if (tasks.isNotEmpty &&
        tasks.every((task) => task.state == WorkshopDurableState.completed)) {
      return _projectTransition(
        snapshot,
        WorkshopDurableState.completed,
        reason,
        now,
      );
    }
    if (tasks.isNotEmpty && tasks.every((task) => task.isTerminal)) {
      if (tasks.any((task) => task.state == WorkshopDurableState.failed)) {
        return _projectTransition(
          snapshot,
          WorkshopDurableState.failed,
          reason,
          now,
        );
      }
      if (tasks.any((task) => task.state == WorkshopDurableState.cancelled)) {
        return _projectTransition(
          snapshot,
          WorkshopDurableState.cancelled,
          reason,
          now,
        );
      }
    }
    if (tasks.any((task) => task.state == WorkshopDurableState.running)) {
      return _projectTransition(snapshot, WorkshopDurableState.running, reason, now);
    }
    if (tasks.any((task) => task.state == WorkshopDurableState.validating)) {
      return _projectTransition(
        snapshot,
        WorkshopDurableState.validating,
        reason,
        now,
      );
    }
    if (tasks.any((task) => task.state == WorkshopDurableState.retrying)) {
      return _projectTransition(snapshot, WorkshopDurableState.retrying, reason, now);
    }
    if (tasks.any(
      (task) =>
          task.state == WorkshopDurableState.ready &&
          _dependenciesCompleted(snapshot, task),
    )) {
      // An external wait must never freeze the whole project while independent
      // work is runnable.
      return _projectTransition(snapshot, WorkshopDurableState.ready, reason, now);
    }
    if (tasks.any((task) => task.state == WorkshopDurableState.waitingExternal)) {
      return _projectTransition(
        snapshot,
        WorkshopDurableState.waitingExternal,
        reason,
        now,
      );
    }
    if (tasks.any((task) => task.state == WorkshopDurableState.blocked)) {
      return _projectTransition(snapshot, WorkshopDurableState.blocked, reason, now);
    }
    if (tasks.any((task) => task.state == WorkshopDurableState.failed)) {
      return _projectTransition(snapshot, WorkshopDurableState.failed, reason, now);
    }
    return snapshot;
  }
}

void _validateTaskGraph(Map<String, WorkshopDurableTask> tasks) {
  for (final task in tasks.values) {
    for (final dependency in task.dependencies) {
      if (dependency == task.taskId) {
        throw StateError('Task cannot depend on itself: ' + task.taskId);
      }
      if (!tasks.containsKey(dependency)) {
        throw StateError('Missing task dependency: ' + dependency);
      }
    }
  }

  final visiting = <String>{};
  final visited = <String>{};

  void visit(String id) {
    if (visited.contains(id)) return;
    if (!visiting.add(id)) {
      throw StateError('Durable task graph contains a cycle at: ' + id);
    }
    for (final dependency in tasks[id]!.dependencies) {
      visit(dependency);
    }
    visiting.remove(id);
    visited.add(id);
  }

  for (final id in tasks.keys) {
    visit(id);
  }
}

String _identity(String value, String field) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, field, 'must not be empty');
  }
  return normalized;
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = _optionalString(json[key]);
  if (value == null) throw FormatException('Missing durable field: ' + key);
  return value;
}

String? _optionalString(Object? value) {
  final normalized = value?.toString().trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

DateTime _requiredDate(Map<String, Object?> json, String key) {
  final raw = _requiredString(json, key);
  final value = DateTime.tryParse(raw);
  if (value == null) throw FormatException('Invalid durable date: ' + key);
  return value.toUtc();
}

DateTime? _optionalDate(Object? value) {
  final raw = _optionalString(value);
  if (raw == null) return null;
  return DateTime.tryParse(raw)?.toUtc();
}

List<String> _strings(Object? value) {
  if (value is! List) return const <String>[];
  return List<String>.unmodifiable(
    value
        .map((item) => item?.toString().trim() ?? '')
        .where((item) => item.isNotEmpty),
  );
}

WorkshopDurableState _state(Object? value) {
  final name = _optionalString(value);
  for (final state in WorkshopDurableState.values) {
    if (state.name == name) return state;
  }
  throw FormatException('Unknown durable state: ' + (name ?? 'null'));
}

WorkshopDurableFailureClass? _failureClass(Object? value) {
  final name = _optionalString(value);
  if (name == null) return null;
  for (final failure in WorkshopDurableFailureClass.values) {
    if (failure.name == name) return failure;
  }
  return WorkshopDurableFailureClass.unknown;
}

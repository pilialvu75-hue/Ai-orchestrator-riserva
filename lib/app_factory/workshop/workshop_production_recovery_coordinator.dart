import 'dart:async';
import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/workshop_background_service.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_dashboard_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';

/// Persists the active Cantiere production through the existing Workshop
/// checkpoint store.
///
/// This is deliberately not a second persistence subsystem. The coordinator
/// only projects the authoritative Dashboard/Engine state into the existing
/// [WorkshopCheckpointStore] and rebuilds that state when the Cantiere is
/// opened again.
///
/// Unapproved VirtualWorkspace changes are intentionally not serialized here.
/// If the app process dies while a task is staged/reviewing, recovery reopens
/// the same task against the real workspace and requires the inference/review
/// cycle to run again instead of pretending that an in-memory diff survived.
final class WorkshopProductionRecoveryCoordinator {
  WorkshopProductionRecoveryCoordinator({
    required WorkshopCheckpointStore checkpointStore,
  }) : _checkpointStore = checkpointStore;

  static const String _jobId = 'workshop-production:active:v1';
  static const String _payloadPrefix = 'workshop-production-state-v1:';

  final WorkshopCheckpointStore _checkpointStore;

  WorkshopDashboardController? _controller;
  void Function()? _listener;
  Future<void> _writeTail = Future<void>.value();

  Object? _lastPersistenceError;

  Object? get lastPersistenceError => _lastPersistenceError;

  /// Restores the latest durable production checkpoint, if one exists.
  ///
  /// Corrupt/incompatible payloads are discarded. Operational restoration
  /// failures (for example an unavailable workspace) are rethrown and the
  /// checkpoint is kept, so a transient device problem cannot erase recovery
  /// data.
  Future<bool> restore(
    WorkshopDashboardController controller,
  ) async {
    final checkpoint = await _checkpointStore.load(_jobId);

    if (checkpoint == null ||
        checkpoint.status == WorkshopBackgroundStatus.cancelled) {
      return false;
    }

    late final _WorkshopProductionSnapshot snapshot;

    try {
      snapshot = _WorkshopProductionSnapshot.decode(
        checkpoint.message,
        payloadPrefix: _payloadPrefix,
      );
    } on FormatException {
      await _checkpointStore.remove(_jobId);
      return false;
    }

    await controller.restoreProduction(
      request: snapshot.request,
      plan: snapshot.plan,
      activeTaskId: snapshot.activeTaskId,
    );

    // Re-save after recovery so any intentionally downgraded transient state
    // (for example review -> implementation after losing an in-memory diff)
    // becomes the new durable truth.
    await saveCurrent(controller);

    return true;
  }

  /// Starts observing one production controller.
  ///
  /// State writes are serialized to avoid SharedPreferences read/modify/write
  /// races when several controller notifications arrive close together.
  void attach(
    WorkshopDashboardController controller,
  ) {
    if (identical(_controller, controller)) {
      return;
    }

    final previousController = _controller;
    final previousListener = _listener;

    if (previousController != null && previousListener != null) {
      previousController.removeListener(previousListener);
    }

    _controller = controller;

    final listener = () {
      _queueSnapshot(
        _WorkshopProductionSnapshot.capture(controller),
      );
    };

    _listener = listener;
    controller.addListener(listener);
  }

  /// Flushes the current controller state and stops observing it.
  Future<void> detach({
    bool flushCurrent = true,
  }) async {
    final controller = _controller;
    final listener = _listener;

    if (controller != null && listener != null) {
      controller.removeListener(listener);
    }

    _controller = null;
    _listener = null;

    if (flushCurrent && controller != null) {
      _queueSnapshot(
        _WorkshopProductionSnapshot.capture(controller),
      );
    }

    await _writeTail;
  }

  /// Persists the latest authoritative production state immediately.
  Future<void> saveCurrent(
    WorkshopDashboardController controller,
  ) async {
    final snapshot =
        _WorkshopProductionSnapshot.capture(controller);

    final previous = _writeTail;
    await previous;
    await _persistSnapshot(snapshot);
  }

  Future<void> clear() async {
    final previous = _writeTail;
    await previous;
    await _checkpointStore.remove(_jobId);
  }

  void _queueSnapshot(
    _WorkshopProductionSnapshot? snapshot,
  ) {
    final previous = _writeTail;

    _writeTail = () async {
      await previous;

      try {
        await _persistSnapshot(snapshot);
        _lastPersistenceError = null;
      } catch (error) {
        // Persistence must never crash or cancel an active Cantiere task. The
        // error remains observable for diagnostics and a later flush can retry.
        _lastPersistenceError = error;
      }
    }();
  }

  Future<void> _persistSnapshot(
    _WorkshopProductionSnapshot? snapshot,
  ) async {
    if (snapshot == null ||
        snapshot.plan.status == WorkshopProjectStatus.cancelled) {
      await _checkpointStore.remove(_jobId);
      return;
    }

    final status = snapshot.plan.status == WorkshopProjectStatus.completed
        ? WorkshopBackgroundStatus.completed
        : WorkshopBackgroundStatus.running;

    await _checkpointStore.save(
      WorkshopBackgroundCheckpoint(
        jobId: _jobId,
        requestId: snapshot.request.id,
        status: status,
        updatedAt: DateTime.now().toUtc(),
        projectId: snapshot.plan.id,
        taskId: snapshot.activeTaskId,
        completedTasks: snapshot.plan.completedTasks,
        totalTasks: snapshot.plan.totalTasks,
        message:
            '$_payloadPrefix${jsonEncode(snapshot.toJson())}',
      ),
    );
  }
}

final class _WorkshopProductionSnapshot {
  const _WorkshopProductionSnapshot({
    required this.request,
    required this.plan,
    required this.stage,
    this.activeTaskId,
  });

  final WorkshopRequest request;
  final WorkshopProjectPlan plan;
  final WorkshopStage? stage;
  final String? activeTaskId;

  static _WorkshopProductionSnapshot? capture(
    WorkshopDashboardController controller,
  ) {
    final state = controller.state;
    final requestId = state.requestId?.trim();

    if (requestId == null || requestId.isEmpty) {
      return null;
    }

    final plan = controller.engine.planOf(requestId);

    if (plan == null) {
      return null;
    }

    // Dashboard-created productions currently originate from the Cantiere and
    // use create semantics. Persisting the complete plan keeps the recovery
    // payload independent from Assistant configuration or memory.
    final request = WorkshopRequest(
      id: requestId,
      title: plan.title,
      instruction: plan.goal,
      source: WorkshopRequestSource.workshop,
      operation: WorkshopOperation.create,
      constraints: plan.constraints,
    );

    return _WorkshopProductionSnapshot(
      request: request,
      plan: plan,
      stage: state.stage ?? controller.engine.stageOf(requestId),
      activeTaskId: state.activeTaskId,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': 1,
        'request': _encodeRequest(request),
        'plan': _encodePlan(plan),
        'stage': stage?.name,
        'activeTaskId': activeTaskId,
      };

  static _WorkshopProductionSnapshot decode(
    String? encoded, {
    required String payloadPrefix,
  }) {
    final raw = encoded?.trim();

    if (raw == null ||
        raw.isEmpty ||
        !raw.startsWith(payloadPrefix)) {
      throw const FormatException(
        'Workshop production recovery payload is missing.',
      );
    }

    final decoded = jsonDecode(
      raw.substring(payloadPrefix.length),
    );

    if (decoded is! Map) {
      throw const FormatException(
        'Workshop production recovery payload is invalid.',
      );
    }

    final root = Map<String, dynamic>.from(decoded);

    if (root['version'] != 1 ||
        root['request'] is! Map ||
        root['plan'] is! Map) {
      throw const FormatException(
        'Unsupported Workshop production recovery payload.',
      );
    }

    final request = _decodeRequest(
      Map<String, dynamic>.from(root['request'] as Map),
    );
    final plan = _decodePlan(
      Map<String, dynamic>.from(root['plan'] as Map),
    );

    if (plan.id != 'project:${request.id}') {
      throw FormatException(
        'Recovered Workshop project ${plan.id} does not belong to '
        'request ${request.id}.',
      );
    }

    final activeTaskId = _nullableString(
      root['activeTaskId'],
    );

    if (activeTaskId != null &&
        plan.taskById(activeTaskId) == null) {
      throw FormatException(
        'Recovered Workshop task $activeTaskId does not exist.',
      );
    }

    return _WorkshopProductionSnapshot(
      request: request,
      plan: plan,
      stage: _nullableEnumByName(
        WorkshopStage.values,
        root['stage'],
      ),
      activeTaskId: activeTaskId,
    );
  }

  static Map<String, dynamic> _encodeRequest(
    WorkshopRequest request,
  ) =>
      <String, dynamic>{
        'id': request.id,
        'title': request.title,
        'instruction': request.instruction,
        'source': request.source.name,
        'operation': request.operation.name,
        'projectPath': request.projectPath,
        'targetFiles': request.targetFiles,
        'constraints': request.constraints,
        'context': request.context,
      };

  static WorkshopRequest _decodeRequest(
    Map<String, dynamic> json,
  ) {
    return WorkshopRequest(
      id: _requiredString(json, 'id'),
      title: _requiredString(json, 'title'),
      instruction: _requiredString(json, 'instruction'),
      source: _enumByName(
        WorkshopRequestSource.values,
        json['source'],
        'request.source',
      ),
      operation: _enumByName(
        WorkshopOperation.values,
        json['operation'],
        'request.operation',
      ),
      projectPath: _nullableString(json['projectPath']),
      targetFiles: _strings(json['targetFiles']),
      constraints: _strings(json['constraints']),
      context: _strings(json['context']),
    );
  }

  static Map<String, dynamic> _encodePlan(
    WorkshopProjectPlan plan,
  ) =>
      <String, dynamic>{
        'id': plan.id,
        'title': plan.title,
        'goal': plan.goal,
        'domain': plan.domain.name,
        'status': plan.status.name,
        'createdAt': plan.createdAt.toUtc().toIso8601String(),
        'updatedAt': plan.updatedAt.toUtc().toIso8601String(),
        'requirements': plan.requirements,
        'constraints': plan.constraints,
        'assumptions': plan.assumptions,
        'technologies': plan.technologies,
        'hardware': plan.hardware,
        'deliverables': plan.deliverables,
        'validationCriteria': plan.validationCriteria,
        'risks': plan.risks,
        'phases': plan.phases.map(_encodePhase).toList(growable: false),
        'tasks': plan.tasks.map(_encodeTask).toList(growable: false),
      };

  static WorkshopProjectPlan _decodePlan(
    Map<String, dynamic> json,
  ) {
    return WorkshopProjectPlan(
      id: _requiredString(json, 'id'),
      title: _requiredString(json, 'title'),
      goal: _requiredString(json, 'goal'),
      domain: _enumByName(
        WorkshopProjectDomain.values,
        json['domain'],
        'plan.domain',
      ),
      status: _enumByName(
        WorkshopProjectStatus.values,
        json['status'],
        'plan.status',
      ),
      createdAt: _date(json['createdAt'], 'plan.createdAt'),
      updatedAt: _date(json['updatedAt'], 'plan.updatedAt'),
      requirements: _strings(json['requirements']),
      constraints: _strings(json['constraints']),
      assumptions: _strings(json['assumptions']),
      technologies: _strings(json['technologies']),
      hardware: _strings(json['hardware']),
      deliverables: _strings(json['deliverables']),
      validationCriteria: _strings(json['validationCriteria']),
      risks: _strings(json['risks']),
      phases: _maps(json['phases'])
          .map(_decodePhase)
          .toList(growable: false),
      tasks: _maps(json['tasks'])
          .map(_decodeTask)
          .toList(growable: false),
    );
  }

  static Map<String, dynamic> _encodePhase(
    WorkshopProjectPhase phase,
  ) =>
      <String, dynamic>{
        'id': phase.id,
        'title': phase.title,
        'description': phase.description,
        'status': phase.status.name,
        'priority': phase.priority.name,
        'taskIds': phase.taskIds,
        'dependencies': phase.dependencies,
        'affectedPaths': phase.affectedPaths,
        'validationCriteria': phase.validationCriteria,
      };

  static WorkshopProjectPhase _decodePhase(
    Map<String, dynamic> json,
  ) {
    return WorkshopProjectPhase(
      id: _requiredString(json, 'id'),
      title: _requiredString(json, 'title'),
      description: _requiredString(json, 'description'),
      status: _enumByName(
        WorkshopProjectPhaseStatus.values,
        json['status'],
        'phase.status',
      ),
      priority: _enumByName(
        WorkshopProjectPriority.values,
        json['priority'],
        'phase.priority',
      ),
      taskIds: _strings(json['taskIds']),
      dependencies: _strings(json['dependencies']),
      affectedPaths: _strings(json['affectedPaths']),
      validationCriteria: _strings(json['validationCriteria']),
    );
  }

  static Map<String, dynamic> _encodeTask(
    WorkshopProjectTask task,
  ) =>
      <String, dynamic>{
        'id': task.id,
        'title': task.title,
        'description': task.description,
        'phaseId': task.phaseId,
        'priority': task.priority.name,
        'completed': task.completed,
        'dependencies': task.dependencies,
        'affectedPaths': task.affectedPaths,
        'validationCriteria': task.validationCriteria,
      };

  static WorkshopProjectTask _decodeTask(
    Map<String, dynamic> json,
  ) {
    return WorkshopProjectTask(
      id: _requiredString(json, 'id'),
      title: _requiredString(json, 'title'),
      description: _requiredString(json, 'description'),
      phaseId: _requiredString(json, 'phaseId'),
      priority: _enumByName(
        WorkshopProjectPriority.values,
        json['priority'],
        'task.priority',
      ),
      completed: json['completed'] == true,
      dependencies: _strings(json['dependencies']),
      affectedPaths: _strings(json['affectedPaths']),
      validationCriteria: _strings(json['validationCriteria']),
    );
  }

  static String _requiredString(
    Map<String, dynamic> json,
    String key,
  ) {
    final value = _nullableString(json[key]);

    if (value == null) {
      throw FormatException(
        'Workshop production recovery field $key is missing.',
      );
    }

    return value;
  }

  static String? _nullableString(Object? value) {
    final normalized = value?.toString().trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  static List<String> _strings(Object? value) {
    if (value is! Iterable) {
      return const <String>[];
    }

    return List<String>.unmodifiable(
      value
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty),
    );
  }

  static List<Map<String, dynamic>> _maps(Object? value) {
    if (value is! Iterable) {
      return const <Map<String, dynamic>>[];
    }

    return value
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

  static DateTime _date(Object? value, String field) {
    final parsed = DateTime.tryParse(value?.toString() ?? '');

    if (parsed == null) {
      throw FormatException(
        'Workshop production recovery $field is invalid.',
      );
    }

    return parsed.toUtc();
  }

  static T _enumByName<T extends Enum>(
    Iterable<T> values,
    Object? raw,
    String field,
  ) {
    final name = _nullableString(raw);

    if (name != null) {
      for (final value in values) {
        if (value.name == name) {
          return value;
        }
      }
    }

    throw FormatException(
      'Workshop production recovery $field is invalid.',
    );
  }

  static T? _nullableEnumByName<T extends Enum>(
    Iterable<T> values,
    Object? raw,
  ) {
    final name = _nullableString(raw);

    if (name == null) {
      return null;
    }

    for (final value in values) {
      if (value.name == name) {
        return value;
      }
    }

    throw FormatException(
      'Unknown Workshop production recovery enum: $name',
    );
  }
}

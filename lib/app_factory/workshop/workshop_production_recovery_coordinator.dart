import 'dart:async';
import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/workshop_background_service.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_capability_shopping_list.dart';
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
final class WorkshopSavedProjectSummary {
  const WorkshopSavedProjectSummary({
    required this.projectId,
    required this.requestId,
    required this.title,
    required this.status,
    required this.progress,
    required this.updatedAt,
    this.activeTaskId,
  });

  final String projectId;
  final String requestId;
  final String title;
  final WorkshopProjectStatus status;
  final double progress;
  final DateTime updatedAt;
  final String? activeTaskId;
}

final class WorkshopProductionRecoveryCoordinator {
  WorkshopProductionRecoveryCoordinator({
    required WorkshopCheckpointStore checkpointStore,
  }) : _checkpointStore = checkpointStore;

  static const String _legacyJobId = 'workshop-production:active:v1';
  static const String _projectJobPrefix = 'workshop-production:project:v2:';
  static const String _payloadPrefix = 'workshop-production-state-v1:';

  final WorkshopCheckpointStore _checkpointStore;

  WorkshopDashboardController? _controller;
  void Function()? _listener;
  Future<void> _writeTail = Future<void>.value();

  Object? _lastPersistenceError;

  Object? get lastPersistenceError => _lastPersistenceError;

  /// Lists durable Cantiere projects without attaching any of them to the UI.
  ///
  /// Opening the Cantiere must always start from a neutral workspace. Recovery
  /// is therefore an explicit user action performed from the Projects menu.
  Future<List<WorkshopSavedProjectSummary>> listSavedProjects() async {
    final checkpoints = await _checkpointStore.loadAll();
    final byProject = <String, WorkshopSavedProjectSummary>{};

    for (final checkpoint in checkpoints) {
      if (!_isProductionCheckpoint(checkpoint.jobId) ||
          checkpoint.status == WorkshopBackgroundStatus.cancelled) {
        continue;
      }

      try {
        final snapshot = _WorkshopProductionSnapshot.decode(
          checkpoint.message,
          payloadPrefix: _payloadPrefix,
        );
        if (snapshot.plan.status == WorkshopProjectStatus.cancelled) {
          continue;
        }

        final candidate = WorkshopSavedProjectSummary(
          projectId: snapshot.plan.id,
          requestId: snapshot.request.id,
          title: snapshot.plan.title,
          status: snapshot.plan.status,
          progress: snapshot.plan.progress,
          updatedAt: checkpoint.updatedAt.toUtc(),
          activeTaskId: snapshot.activeTaskId,
        );
        final previous = byProject[candidate.projectId];
        if (previous == null ||
            candidate.updatedAt.isAfter(previous.updatedAt)) {
          byProject[candidate.projectId] = candidate;
        }
      } on FormatException {
        // One damaged project must not hide the remaining recoverable projects.
      }
    }

    final result = byProject.values.toList(growable: false)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List<WorkshopSavedProjectSummary>.unmodifiable(result);
  }

  /// Backward-compatible explicit restore of the most recently saved project.
  ///
  /// AppShell deliberately does not call this during Cantiere startup.
  Future<bool> restore(
    WorkshopDashboardController controller,
  ) async {
    final projects = await listSavedProjects();
    if (projects.isEmpty) {
      return false;
    }
    return restoreProject(
      controller,
      projectId: projects.first.projectId,
    );
  }

  /// Restores exactly the project selected by the owner.
  Future<bool> restoreProject(
    WorkshopDashboardController controller, {
    required String projectId,
  }) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return false;
    }

    final checkpoints = await _checkpointStore.loadAll();
    final candidates = checkpoints
        .where((checkpoint) =>
            _isProductionCheckpoint(checkpoint.jobId) &&
            checkpoint.status != WorkshopBackgroundStatus.cancelled)
        .toList(growable: false)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    for (final checkpoint in candidates) {
      late final _WorkshopProductionSnapshot snapshot;
      try {
        snapshot = _WorkshopProductionSnapshot.decode(
          checkpoint.message,
          payloadPrefix: _payloadPrefix,
        );
      } on FormatException {
        continue;
      }

      if (snapshot.plan.id != normalizedProjectId ||
          snapshot.plan.status == WorkshopProjectStatus.cancelled) {
        continue;
      }

      await controller.restoreProduction(
        request: snapshot.request,
        plan: snapshot.plan,
        activeTaskId: snapshot.activeTaskId,
        projectApproval: snapshot.projectApproval,
      );

      // Migrate legacy single-slot recovery transparently to the project-scoped
      // catalogue the first time the owner explicitly resumes it.
      await saveCurrent(controller);
      if (checkpoint.jobId == _legacyJobId) {
        await _checkpointStore.remove(_legacyJobId);
      }
      return true;
    }

    return false;
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

    await _runSerializedPersistence(
      () => _persistSnapshot(snapshot),
    );
  }

  Future<void> clear() async {
    await _runSerializedPersistence(() async {
      final checkpoints = await _checkpointStore.loadAll();
      for (final checkpoint in checkpoints) {
        if (_isProductionCheckpoint(checkpoint.jobId)) {
          await _checkpointStore.remove(checkpoint.jobId);
        }
      }
    });
  }

  Future<void> removeProject(String projectId) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return;
    }

    await _runSerializedPersistence(() async {
      final checkpoints = await _checkpointStore.loadAll();
      for (final checkpoint in checkpoints) {
        if (!_isProductionCheckpoint(checkpoint.jobId)) {
          continue;
        }
        try {
          final snapshot = _WorkshopProductionSnapshot.decode(
            checkpoint.message,
            payloadPrefix: _payloadPrefix,
          );
          if (snapshot.plan.id == normalizedProjectId) {
            await _checkpointStore.remove(checkpoint.jobId);
          }
        } on FormatException {
          // Ignore unrelated damaged entries.
        }
      }
    });
  }

  Future<void> _runSerializedPersistence(
    Future<void> Function() operation,
  ) async {
    final previous = _writeTail;
    final current = () async {
      await previous;
      await operation();
    }();

    // Keep the internal tail non-throwing so one failed persistence attempt
    // cannot poison all later checkpoints. The caller still awaits [current]
    // and therefore receives the original failure.
    _writeTail = current.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );

    try {
      await current;
      _lastPersistenceError = null;
    } catch (error) {
      _lastPersistenceError = error;
      rethrow;
    }
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
    // A neutral Cantiere view is not a request to delete parked projects.
    if (snapshot == null) {
      return;
    }

    final jobId = _jobIdForProject(snapshot.plan.id);

    if (snapshot.plan.status == WorkshopProjectStatus.cancelled) {
      await _checkpointStore.remove(jobId);
      await _removeMatchingLegacyCheckpoint(snapshot.plan.id);
      return;
    }

    final status = snapshot.plan.status == WorkshopProjectStatus.completed
        ? WorkshopBackgroundStatus.completed
        : WorkshopBackgroundStatus.running;

    await _checkpointStore.save(
      WorkshopBackgroundCheckpoint(
        jobId: jobId,
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

    await _removeMatchingLegacyCheckpoint(snapshot.plan.id);
  }

  String _jobIdForProject(String projectId) =>
      '$_projectJobPrefix${Uri.encodeComponent(projectId)}';

  bool _isProductionCheckpoint(String jobId) =>
      jobId == _legacyJobId || jobId.startsWith(_projectJobPrefix);

  Future<void> _removeMatchingLegacyCheckpoint(String projectId) async {
    final legacy = await _checkpointStore.load(_legacyJobId);
    if (legacy == null) {
      return;
    }

    try {
      final snapshot = _WorkshopProductionSnapshot.decode(
        legacy.message,
        payloadPrefix: _payloadPrefix,
      );
      if (snapshot.plan.id == projectId) {
        await _checkpointStore.remove(_legacyJobId);
      }
    } on FormatException {
      // A corrupt legacy slot is safe to discard once v2 persistence is active.
      await _checkpointStore.remove(_legacyJobId);
    }
  }

}

final class _WorkshopProductionSnapshot {
  const _WorkshopProductionSnapshot({
    required this.request,
    required this.plan,
    required this.stage,
    this.activeTaskId,
    this.projectApproval,
  });

  final WorkshopRequest request;
  final WorkshopProjectPlan plan;
  final WorkshopStage? stage;
  final String? activeTaskId;
  final WorkshopProjectApprovalEvidence? projectApproval;

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

    final request = controller.engine.requestOf(requestId);

    if (request == null) {
      return null;
    }

    return _WorkshopProductionSnapshot(
      request: request,
      plan: plan,
      stage: state.stage ?? controller.engine.stageOf(requestId),
      activeTaskId: state.activeTaskId,
      projectApproval: state.projectApproval,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': 1,
        'request': _encodeRequest(request),
        'plan': _encodePlan(plan),
        'stage': stage?.name,
        'activeTaskId': activeTaskId,
        'projectApproval': projectApproval?.toJson(),
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
    final projectApproval = _decodeProjectApproval(
      root['projectApproval'],
    );

    if (projectApproval != null &&
        projectApproval.projectId.trim() != plan.id.trim()) {
      throw FormatException(
        'Recovered Workshop approval belongs to project '
        '${projectApproval.projectId}, not ${plan.id}.',
      );
    }

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
      projectApproval: projectApproval,
    );
  }

  static WorkshopProjectApprovalEvidence? _decodeProjectApproval(
    Object? raw,
  ) {
    if (raw == null) {
      return null;
    }

    if (raw is! Map) {
      throw const FormatException(
        'Workshop production recovery project approval is invalid.',
      );
    }

    final json = Map<String, dynamic>.from(raw);
    final projectId = _requiredString(json, 'projectId');
    final approvalId = _requiredString(json, 'approvalId');
    final approvedBy = _requiredString(json, 'approvedBy');

    return WorkshopProjectApprovalEvidence(
      projectId: projectId,
      approvalId: approvalId,
      approvedAt: _date(
        json['approvedAt'],
        'projectApproval.approvedAt',
      ),
      approvedBy: approvedBy,
      derivedFromApprovalId:
          _nullableString(json['derivedFromApprovalId']),
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

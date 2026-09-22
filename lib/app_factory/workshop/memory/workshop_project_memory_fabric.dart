import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_orchestrator.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_execution_journal.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_resume_context.dart';
import 'package:ai_orchestrator/core/memory/fabric/memory_fabric.dart';
import 'package:ai_orchestrator/core/memory/fabric/memory_fabric_record.dart';
import 'package:uuid/uuid.dart';

/// Read-only durable projection of one Cantiere project into Memory Fabric.
///
/// Cantiere remains authoritative for Project/Task/Execution/checkpoint state.
/// This object exists only to make the already-authoritative state durable,
/// searchable and replicable through the provider-neutral Memory Fabric.
final class WorkshopProjectMemorySnapshot {
  WorkshopProjectMemorySnapshot({
    required this.projectId,
    required this.requestId,
    required this.title,
    required this.originalRequest,
    required this.status,
    required this.requirements,
    required this.decisions,
    required this.plan,
    required this.tasks,
    required this.attempts,
    required this.errors,
    required this.fixes,
    required this.ci,
    required this.artifacts,
    required this.tests,
    required this.completionCriteria,
    required this.createdAt,
    required this.updatedAt,
    this.correlationId,
    this.activeTaskId,
    this.lastError,
    this.nextStep,
  })  : requirements = List<String>.unmodifiable(requirements),
        decisions = List<String>.unmodifiable(decisions),
        plan = Map<String, Object?>.unmodifiable(plan),
        tasks = _freezeMaps(tasks),
        attempts = _freezeMaps(attempts),
        errors = _freezeMaps(errors),
        fixes = List<String>.unmodifiable(fixes),
        ci = _freezeMaps(ci),
        artifacts = List<String>.unmodifiable(artifacts),
        tests = _freezeMaps(tests),
        completionCriteria =
            List<String>.unmodifiable(completionCriteria);

  final String projectId;
  final String requestId;
  final String title;
  final String originalRequest;
  final String status;
  final List<String> requirements;
  final List<String> decisions;
  final Map<String, Object?> plan;
  final List<Map<String, Object?>> tasks;
  final List<Map<String, Object?>> attempts;
  final List<Map<String, Object?>> errors;
  final List<String> fixes;
  final List<Map<String, Object?>> ci;
  final List<String> artifacts;
  final List<Map<String, Object?>> tests;
  final List<String> completionCriteria;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? correlationId;
  final String? activeTaskId;
  final String? lastError;
  final String? nextStep;

  factory WorkshopProjectMemorySnapshot.capture({
    required WorkshopRequest request,
    required WorkshopProjectPlan plan,
    WorkshopDurableProjectSnapshot? durable,
    WorkshopResumeContext? resumeContext,
    List<WorkshopExecutionRecord> executions =
        const <WorkshopExecutionRecord>[],
    List<String> fixes = const <String>[],
    List<Map<String, Object?>> ciEvidence =
        const <Map<String, Object?>>[],
    List<Map<String, Object?>> testEvidence =
        const <Map<String, Object?>>[],
  }) {
    _ensureProjectIdentity(
      plan: plan,
      durable: durable,
      resumeContext: resumeContext,
    );

    final executionList = List<WorkshopExecutionRecord>.of(executions)
      ..sort((a, b) => a.completedAt.compareTo(b.completedAt));

    final decisions = <String>{
      ...?resumeContext?.decisions,
      ..._metadataStrings(executionList, 'decisions'),
    };

    final verified = <String>{
      ...?resumeContext?.verified,
      ..._metadataStrings(executionList, 'verified'),
    };

    final collectedFixes = <String>{
      ...fixes.map((item) => item.trim()).where((item) => item.isNotEmpty),
      ..._metadataStrings(executionList, 'fixes'),
    };

    final artifacts = <String>{
      ...?resumeContext?.artifacts,
      for (final execution in executionList) ...execution.artifacts,
      if (durable != null)
        for (final task in durable.tasks.values) ...task.artifactIds,
      if (durable != null)
        for (final event in durable.events) ...event.artifactIds,
    }..removeWhere((item) => item.trim().isEmpty);

    final errors = <Map<String, Object?>>[
      for (final execution in executionList)
        if (_optional(execution.error) != null)
          <String, Object?>{
            'source': 'execution',
            'execution_id': execution.id,
            'task_id': execution.taskId,
            'error': execution.error!.trim(),
            'timestamp': execution.completedAt.toUtc().toIso8601String(),
          },
      if (durable != null)
        for (final task in durable.tasks.values)
          if (_optional(task.blockedReasonCode) != null)
            <String, Object?>{
              'source': 'durable_task',
              'task_id': task.taskId,
              'error': task.blockedReasonCode,
              'timestamp': task.updatedAt.toUtc().toIso8601String(),
            },
      if (durable != null)
        for (final event in durable.events)
          if (!event.success && event.failureClass != null)
            <String, Object?>{
              'source': 'durable_event',
              'task_id': event.taskId,
              'error': event.failureClass!.name,
              'event_type': event.type,
              'timestamp': event.occurredAt.toUtc().toIso8601String(),
            },
    ];

    final ci = <Map<String, Object?>>[
      ...ciEvidence.map(Map<String, Object?>.from),
      if (durable != null)
        for (final event in durable.events)
          if (event.type == WorkshopDurableEventTypes.ciStarted ||
              event.type == WorkshopDurableEventTypes.ciCompleted)
            <String, Object?>{
              'event_type': event.type,
              'task_id': event.taskId,
              'success': event.success,
              'external_id': event.externalId,
              'timestamp': event.occurredAt.toUtc().toIso8601String(),
              'artifact_ids': event.artifactIds,
              if (event.failureClass != null)
                'failure_class': event.failureClass!.name,
            },
    ];

    final tests = <Map<String, Object?>>[
      ...testEvidence.map(Map<String, Object?>.from),
      for (final item in verified)
        <String, Object?>{
          'name': item,
          'status': 'verified',
        },
    ];

    final completionCriteria = <String>{
      ...plan.validationCriteria,
      for (final task in plan.tasks) ...task.validationCriteria,
    }..removeWhere((item) => item.trim().isEmpty);

    final attempts = <Map<String, Object?>>[
      for (final execution in executionList)
        <String, Object?>{
          'execution_id': execution.id,
          'task_id': execution.taskId,
          'status': execution.status,
          'started_at': execution.startedAt.toUtc().toIso8601String(),
          'completed_at': execution.completedAt.toUtc().toIso8601String(),
          'provider_id': execution.providerId,
          'resource': execution.resource,
          'mode': execution.mode,
          'checkpoint': execution.checkpoint,
          'changed_files': execution.changedFiles,
          'artifacts': execution.artifacts,
          'latency_ms': execution.latencyMs,
          'used_fallback': execution.usedFallback,
        },
    ];

    final tasks = <Map<String, Object?>>[
      for (final task in plan.tasks)
        <String, Object?>{
          'id': task.id,
          'title': task.title,
          'description': task.description,
          'phase_id': task.phaseId,
          'priority': task.priority.name,
          'completed': task.completed,
          'dependencies': task.dependencies,
          'affected_paths': task.affectedPaths,
          'validation_criteria': task.validationCriteria,
          if (durable?.tasks[task.id] != null)
            'durable_state': durable!.tasks[task.id]!.state.name,
          if (durable?.tasks[task.id] != null)
            'attempts_started': durable!.tasks[task.id]!.attemptsStarted,
          if (durable?.tasks[task.id] != null)
            'durable_artifact_ids': durable!.tasks[task.id]!.artifactIds,
          if (_optional(durable?.tasks[task.id]?.blockedReasonCode) != null)
            'blocked_reason_code':
                durable!.tasks[task.id]!.blockedReasonCode,
        },
    ];

    final planData = <String, Object?>{
      'id': plan.id,
      'title': plan.title,
      'goal': plan.goal,
      'domain': plan.domain.name,
      'status': plan.status.name,
      'created_at': plan.createdAt.toUtc().toIso8601String(),
      'updated_at': plan.updatedAt.toUtc().toIso8601String(),
      'constraints': plan.constraints,
      'assumptions': plan.assumptions,
      'technologies': plan.technologies,
      'hardware': plan.hardware,
      'deliverables': plan.deliverables,
      'risks': plan.risks,
      'phases': <Map<String, Object?>>[
        for (final phase in plan.phases)
          <String, Object?>{
            'id': phase.id,
            'title': phase.title,
            'description': phase.description,
            'status': phase.status.name,
            'priority': phase.priority.name,
            'task_ids': phase.taskIds,
            'dependencies': phase.dependencies,
            'affected_paths': phase.affectedPaths,
            'validation_criteria': phase.validationCriteria,
          },
      ],
    };

    final lastError = errors.isEmpty
        ? null
        : _optional(errors.last['error']?.toString());

    final nextStep = _optional(resumeContext?.nextStep) ??
        _firstNonEmpty(resumeContext?.remainingWork) ??
        _optional(plan.nextAvailableTask?.title);

    final status = durable?.state.name ?? plan.status.name;
    final updatedAt = _latestDate(<DateTime>[
      plan.updatedAt,
      if (durable != null) durable.updatedAt,
      if (executionList.isNotEmpty) executionList.last.completedAt,
    ]);

    return WorkshopProjectMemorySnapshot(
      projectId: plan.id,
      requestId: request.id,
      title: plan.title,
      originalRequest: request.instruction,
      status: status,
      requirements: plan.requirements,
      decisions: decisions.toList(growable: false),
      plan: planData,
      tasks: tasks,
      attempts: attempts,
      errors: errors,
      fixes: collectedFixes.toList(growable: false),
      ci: ci,
      artifacts: artifacts.toList(growable: false),
      tests: tests,
      completionCriteria: completionCriteria.toList(growable: false),
      createdAt: plan.createdAt.toUtc(),
      updatedAt: updatedAt,
      correlationId: durable?.correlationId,
      activeTaskId: _optional(resumeContext?.taskId) ??
          _activeDurableTaskId(durable),
      lastError: lastError,
      nextStep: nextStep,
    );
  }

  Map<String, Object?> toStructuredData() => <String, Object?>{
        'project_id': projectId,
        'request_id': requestId,
        'title': title,
        'original_request': originalRequest,
        'status': status,
        'requirements': requirements,
        'decisions': decisions,
        'plan': plan,
        'tasks': tasks,
        'attempts': attempts,
        'errors': errors,
        'fixes': fixes,
        'ci': ci,
        'artifacts': artifacts,
        'tests': tests,
        'completion_criteria': completionCriteria,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
        'correlation_id': correlationId,
        'active_task_id': activeTaskId,
        'last_error': lastError,
        'next_step': nextStep,
      };

  factory WorkshopProjectMemorySnapshot.fromStructuredData(
    Map<String, Object?> data,
  ) {
    return WorkshopProjectMemorySnapshot(
      projectId: _required(data, 'project_id'),
      requestId: _required(data, 'request_id'),
      title: _required(data, 'title'),
      originalRequest: _required(data, 'original_request'),
      status: _required(data, 'status'),
      requirements: _strings(data['requirements']),
      decisions: _strings(data['decisions']),
      plan: _map(data['plan']),
      tasks: _maps(data['tasks']),
      attempts: _maps(data['attempts']),
      errors: _maps(data['errors']),
      fixes: _strings(data['fixes']),
      ci: _maps(data['ci']),
      artifacts: _strings(data['artifacts']),
      tests: _maps(data['tests']),
      completionCriteria: _strings(data['completion_criteria']),
      createdAt: _date(data['created_at'], 'created_at'),
      updatedAt: _date(data['updated_at'], 'updated_at'),
      correlationId: _optional(data['correlation_id']?.toString()),
      activeTaskId: _optional(data['active_task_id']?.toString()),
      lastError: _optional(data['last_error']?.toString()),
      nextStep: _optional(data['next_step']?.toString()),
    );
  }
}

/// Stable Project Memory API over Memory Fabric.
///
/// This service writes a projection only. It does not restore or mutate the
/// Cantiere. Project recovery continues to use the authoritative Cantiere
/// checkpoint/recovery stores.
final class WorkshopProjectMemoryFabricService {
  const WorkshopProjectMemoryFabricService({
    required MemoryFabric memory,
  }) : _memory = memory;

  static const String namespace = 'airlab.project';
  static const String subject = 'project_state';
  static const String source = 'cantiere_project_state';

  final MemoryFabric _memory;

  Future<MemoryFabricRecord> save({
    required WorkshopRequest request,
    required WorkshopProjectPlan plan,
    WorkshopDurableProjectSnapshot? durable,
    WorkshopResumeContext? resumeContext,
    List<WorkshopExecutionRecord> executions =
        const <WorkshopExecutionRecord>[],
    List<String> fixes = const <String>[],
    List<Map<String, Object?>> ciEvidence =
        const <Map<String, Object?>>[],
    List<Map<String, Object?>> testEvidence =
        const <Map<String, Object?>>[],
  }) async {
    final snapshot = WorkshopProjectMemorySnapshot.capture(
      request: request,
      plan: plan,
      durable: durable,
      resumeContext: resumeContext,
      executions: executions,
      fixes: fixes,
      ciEvidence: ciEvidence,
      testEvidence: testEvidence,
    );
    final recordId = recordIdForProject(snapshot.projectId);
    final existing = await _memory.read(recordId);
    final structuredData = snapshot.toStructuredData();
    final content = _summary(snapshot);

    final record = existing == null
        ? MemoryFabricRecord.create(
            id: recordId,
            namespace: namespace,
            type: MemoryFabricType.project,
            subject: subject,
            content: content,
            source: source,
            structuredData: structuredData,
            privacyLevel: MemoryFabricPrivacyLevel.project,
            tags: const <String>[
              'project',
              'cantiere',
              'checkpoint',
            ],
            projectId: snapshot.projectId,
          )
        : existing.nextVersion(
            content: content,
            structuredData: structuredData,
            source: source,
          );

    return _memory.write(record);
  }

  Future<WorkshopProjectMemorySnapshot?> load(String projectId) async {
    final normalized = projectId.trim();
    if (normalized.isEmpty) return null;

    final record = await _memory.read(recordIdForProject(normalized));
    if (record == null ||
        record.namespace != namespace ||
        record.type != MemoryFabricType.project ||
        record.subject != subject ||
        record.projectId != normalized) {
      return null;
    }

    try {
      return WorkshopProjectMemorySnapshot.fromStructuredData(
        record.structuredData,
      );
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  Future<MemoryFabricRecord?> loadRecord(String projectId) {
    final normalized = projectId.trim();
    if (normalized.isEmpty) {
      return Future<MemoryFabricRecord?>.value();
    }
    return _memory.read(recordIdForProject(normalized));
  }

  static String recordIdForProject(String projectId) {
    final normalized = projectId.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(projectId, 'projectId', 'is required');
    }
    return const Uuid().v5(
      Namespace.url.value,
      'airlab-project-memory:$normalized',
    );
  }

  static String _summary(WorkshopProjectMemorySnapshot snapshot) {
    return 'Project ${snapshot.projectId}: status=${snapshot.status}; '
        'last_error=${snapshot.lastError ?? 'none'}; '
        'next_step=${snapshot.nextStep ?? 'unspecified'}';
  }
}

void _ensureProjectIdentity({
  required WorkshopProjectPlan plan,
  WorkshopDurableProjectSnapshot? durable,
  WorkshopResumeContext? resumeContext,
}) {
  final projectId = plan.id.trim();
  if (projectId.isEmpty) {
    throw ArgumentError.value(plan.id, 'plan.id', 'is required');
  }
  if (durable != null && durable.projectId.trim() != projectId) {
    throw StateError(
      'Durable project ${durable.projectId} does not match $projectId.',
    );
  }
  if (resumeContext != null && resumeContext.projectId.trim() != projectId) {
    throw StateError(
      'Resume project ${resumeContext.projectId} does not match $projectId.',
    );
  }
}

String? _activeDurableTaskId(WorkshopDurableProjectSnapshot? durable) {
  if (durable == null) return null;
  for (final task in durable.tasks.values) {
    if (!task.isTerminal) return task.taskId;
  }
  return null;
}

Iterable<String> _metadataStrings(
  Iterable<WorkshopExecutionRecord> executions,
  String key,
) sync* {
  for (final execution in executions) {
    final value = execution.metadata[key];
    if (value is! Iterable) continue;
    for (final item in value) {
      final normalized = item.toString().trim();
      if (normalized.isNotEmpty) yield normalized;
    }
  }
}

String? _firstNonEmpty(Iterable<String>? values) {
  if (values == null) return null;
  for (final value in values) {
    final normalized = value.trim();
    if (normalized.isNotEmpty) return normalized;
  }
  return null;
}

DateTime _latestDate(Iterable<DateTime> values) {
  DateTime? latest;
  for (final value in values) {
    final utc = value.toUtc();
    if (latest == null || utc.isAfter(latest)) latest = utc;
  }
  return latest ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
}

List<Map<String, Object?>> _freezeMaps(
  Iterable<Map<String, Object?>> values,
) =>
    List<Map<String, Object?>>.unmodifiable(
      values.map(
        (item) => Map<String, Object?>.unmodifiable(item),
      ),
    );

String _required(Map<String, Object?> data, String key) {
  final value = _optional(data[key]?.toString());
  if (value == null) {
    throw FormatException('Project memory field $key is missing.');
  }
  return value;
}

String? _optional(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

List<String> _strings(Object? value) {
  if (value is! Iterable) return const <String>[];
  return List<String>.unmodifiable(
    value
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty),
  );
}

Map<String, Object?> _map(Object? value) {
  if (value is! Map) return const <String, Object?>{};
  return Map<String, Object?>.unmodifiable(
    <String, Object?>{
      for (final entry in value.entries)
        if (entry.key is String) entry.key as String: entry.value,
    },
  );
}

List<Map<String, Object?>> _maps(Object? value) {
  if (value is! Iterable) return const <Map<String, Object?>>[];
  final result = <Map<String, Object?>>[];
  for (final item in value) {
    if (item is Map) {
      result.add(
        <String, Object?>{
          for (final entry in item.entries)
            if (entry.key is String) entry.key as String: entry.value,
        },
      );
    }
  }
  return List<Map<String, Object?>>.unmodifiable(result);
}

DateTime _date(Object? value, String field) {
  final parsed = DateTime.tryParse(value?.toString() ?? '');
  if (parsed == null) {
    throw FormatException('Invalid Project Memory $field.');
  }
  return parsed.toUtc();
}

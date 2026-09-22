import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_execution_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_task_handle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';

import 'workshop_airlab_inference_bridge.dart';

typedef WorkshopAirLabStagingRootResolver = String Function(
  WorkshopProductionTaskHandle handle,
);

typedef WorkshopAirLabTargetResolver = String Function(
  WorkshopProductionTaskHandle handle,
);

typedef WorkshopAirLabExecutionApprovalResolver = bool Function(
  WorkshopProductionTaskHandle handle,
);

/// Fail-closed mapping error raised before AIrLab receives any production task.
final class WorkshopAirLabProductionMappingException implements Exception {
  const WorkshopAirLabProductionMappingException(
    this.message, {
    required this.code,
    this.path,
  });

  final String message;
  final String code;
  final String? path;

  @override
  String toString() =>
      'WorkshopAirLabProductionMappingException($code): $message';
}

/// Converts the authoritative prepared production handle into the bounded task
/// contract accepted by the A5 AIrLab bridge.
///
/// This first production ring intentionally supports software projects only and
/// never invents a writable file scope. Mutating tasks must provide concrete
/// paths through the project task or Workshop request.
final class WorkshopAirLabProductionTaskMapper {
  const WorkshopAirLabProductionTaskMapper({
    this.maxListItems = 32,
  }) : assert(maxListItems > 0);

  final int maxListItems;

  WorkshopTaskContract map(
    WorkshopProductionTaskHandle handle, {
    required String target,
  }) {
    final normalizedTarget = target.trim();
    if (normalizedTarget.isEmpty) {
      throw const WorkshopAirLabProductionMappingException(
        'AIrLab production execution requires an explicit target.',
        code: 'target_missing',
      );
    }

    final plan = handle.plan;
    if (plan.domain != WorkshopProjectDomain.software) {
      throw WorkshopAirLabProductionMappingException(
        'AIrLab production runner A6 supports only software projects.',
        code: 'unsupported_project_domain',
      );
    }

    final projectTask = plan.taskById(handle.taskId);
    if (projectTask == null) {
      throw WorkshopAirLabProductionMappingException(
        'Prepared Workshop task is missing from the authoritative project plan.',
        code: 'project_task_missing',
      );
    }

    final request = handle.session.context.request;
    final kind = _kindFor(request.operation);
    final mutating = kind == WorkshopTaskKind.codeGeneration ||
        kind == WorkshopTaskKind.codeModification ||
        kind == WorkshopTaskKind.integration;

    final allowed = _normalizedScope(<String>[
      ...projectTask.affectedPaths,
      ...request.targetFiles,
    ]);

    if (mutating && allowed.isEmpty) {
      throw const WorkshopAirLabProductionMappingException(
        'AIrLab production mutation requires an explicit writable file scope.',
        code: 'writable_scope_missing',
      );
    }

    final objective = projectTask.description.trim().isNotEmpty
        ? projectTask.description.trim()
        : request.instruction.trim();
    if (objective.isEmpty) {
      throw const WorkshopAirLabProductionMappingException(
        'AIrLab production task objective is empty.',
        code: 'objective_missing',
      );
    }

    final instructions = _dedupe(<String>[
      projectTask.description,
      request.instruction,
      ...plan.requirements,
      ...plan.deliverables,
    ]);

    final constraints = _dedupe(<String>[
      ...request.constraints,
      ...plan.constraints,
    ]);

    final criteriaText = _dedupe(<String>[
      ...projectTask.validationCriteria,
      ...plan.validationCriteria,
    ]);
    final criteria = <WorkshopTaskAcceptanceCriterion>[
      for (var index = 0; index < criteriaText.length; index += 1)
        WorkshopTaskAcceptanceCriterion(
          id: 'airlab-production-${index + 1}',
          description: criteriaText[index],
        ),
    ];

    return WorkshopTaskContract(
      id: handle.taskId,
      title: projectTask.title.trim().isNotEmpty
          ? projectTask.title.trim()
          : request.title.trim(),
      objective: objective,
      kind: kind,
      mode: WorkshopTaskMode.local,
      preferredResource: WorkshopTaskResource.local,
      fallbackResources: const <WorkshopTaskResource>[],
      priority: _priorityFor(projectTask.priority),
      instructions: instructions,
      constraints: constraints,
      acceptanceCriteria: criteria,
      fileScope: WorkshopTaskFileScope(
        allowed: allowed,
      ),
      dependsOn: _dedupe(projectTask.dependencies),
      tags: _dedupe(plan.technologies),
      metadata: <String, dynamic>{
        'airlabTaskFamily': 'software',
        'projectId': plan.id,
        'airlabProduction': true,
        'airlabTarget': normalizedTarget,
      },
    );
  }

  WorkshopTaskKind _kindFor(WorkshopOperation operation) {
    switch (operation) {
      case WorkshopOperation.analyse:
        return WorkshopTaskKind.analysis;
      case WorkshopOperation.create:
        return WorkshopTaskKind.codeGeneration;
      case WorkshopOperation.modify:
      case WorkshopOperation.remove:
      case WorkshopOperation.refactor:
      case WorkshopOperation.fix:
      case WorkshopOperation.optimize:
        return WorkshopTaskKind.codeModification;
      case WorkshopOperation.validate:
        return WorkshopTaskKind.test;
    }
  }

  WorkshopTaskPriority _priorityFor(WorkshopProjectPriority priority) {
    switch (priority) {
      case WorkshopProjectPriority.low:
        return WorkshopTaskPriority.low;
      case WorkshopProjectPriority.normal:
        return WorkshopTaskPriority.normal;
      case WorkshopProjectPriority.high:
        return WorkshopTaskPriority.high;
      case WorkshopProjectPriority.critical:
        return WorkshopTaskPriority.critical;
    }
  }

  List<String> _normalizedScope(Iterable<String> values) {
    final result = <String>[];
    final seen = <String>{};

    for (final raw in values) {
      if (result.length >= maxListItems) break;
      final normalized = _normalizeScopePath(raw);
      if (normalized != null && seen.add(normalized)) {
        result.add(normalized);
      }
    }

    return List<String>.unmodifiable(result);
  }

  String? _normalizeScopePath(String raw) {
    final value = raw.trim().replaceAll('\\', '/');
    if (value.isEmpty) return null;
    if (value.contains('\u0000')) {
      throw WorkshopAirLabProductionMappingException(
        'AIrLab production scope contains a null byte.',
        code: 'invalid_scope_path',
        path: raw,
      );
    }
    if (value.startsWith('/') || RegExp(r'^[A-Za-z]:/').hasMatch(value)) {
      throw WorkshopAirLabProductionMappingException(
        'AIrLab production scope must be relative.',
        code: 'absolute_scope_path',
        path: raw,
      );
    }

    final subtree = value.endsWith('/');
    final withoutTrailing = value.replaceFirst(RegExp(r'/+$'), '');
    final segments = withoutTrailing.split('/');
    if (withoutTrailing.isEmpty ||
        segments.any((segment) =>
            segment.isEmpty || segment == '.' || segment == '..')) {
      throw WorkshopAirLabProductionMappingException(
        'AIrLab production scope contains traversal or empty segments.',
        code: 'invalid_scope_path',
        path: raw,
      );
    }

    final normalized = segments.join('/');
    return subtree ? '$normalized/' : normalized;
  }

  List<String> _dedupe(Iterable<String> values) {
    final result = <String>[];
    final seen = <String>{};
    for (final raw in values) {
      if (result.length >= maxListItems) break;
      final value = raw.trim();
      if (value.isNotEmpty && seen.add(value)) {
        result.add(value);
      }
    }
    return List<String>.unmodifiable(result);
  }
}

/// Production-controller adapter for an explicitly selected AIrLab execution.
///
/// The controller remains unchanged and receives the same
/// [WorkshopTaskInferenceResult] contract as the historical multi-role runner.
///
/// A6 intentionally implements only [WorkshopProductionExecutionRunner].
/// Therefore retries/restarts use the controller's documented full-replay path
/// instead of pretending AIrLab semantic resume exists.
final class WorkshopAirLabProductionExecutionRunner
    implements WorkshopProductionExecutionRunner {
  WorkshopAirLabProductionExecutionRunner({
    required WorkshopProductionExecutionRunner handleSource,
    required WorkshopAirLabInferenceBridge bridge,
    required WorkshopAirLabStagingRootResolver stagingRootResolver,
    required WorkshopAirLabTargetResolver targetResolver,
    required WorkshopAirLabExecutionApprovalResolver approvalResolver,
    WorkshopAirLabProductionTaskMapper mapper =
        const WorkshopAirLabProductionTaskMapper(),
  })  : _handleSource = handleSource,
        _bridge = bridge,
        _stagingRootResolver = stagingRootResolver,
        _targetResolver = targetResolver,
        _approvalResolver = approvalResolver,
        _mapper = mapper;

  final WorkshopProductionExecutionRunner _handleSource;
  final WorkshopAirLabInferenceBridge _bridge;
  final WorkshopAirLabStagingRootResolver _stagingRootResolver;
  final WorkshopAirLabTargetResolver _targetResolver;
  final WorkshopAirLabExecutionApprovalResolver _approvalResolver;
  final WorkshopAirLabProductionTaskMapper _mapper;

  @override
  WorkshopProductionTaskHandle preparedHandle() =>
      _handleSource.preparedHandle();

  @override
  Future<WorkshopTaskInferenceResult> runPrepared({
    required WorkshopProductionTaskHandle handle,
    required CancellationToken cancellationToken,
    required bool isOffline,
  }) {
    final target = _targetResolver(handle).trim();
    final task = _mapper.map(
      handle,
      target: target,
    );

    final stagingRoot = _stagingRootResolver(handle).trim();
    if (stagingRoot.isEmpty) {
      throw const WorkshopAirLabProductionMappingException(
        'AIrLab production execution requires an explicit staging root.',
        code: 'staging_root_missing',
      );
    }

    return _bridge.run(
      task: task,
      session: handle.session,
      stagingRoot: stagingRoot,
      networkAvailable: !isOffline,
      executionApprovalGranted: _approvalResolver(handle),
      isOffline: isOffline,
      projectId: handle.plan.id,
      target: target,
      cancellationToken: cancellationToken,
    );
  }
}

/// Explicit A6 selection boundary.
///
/// When [enabled] is false this returns [historicalRunner] itself, preserving
/// identity, semantic-resume support and all historical production behavior.
/// No silent AIrLab fallback is attempted in either direction.
abstract final class WorkshopAirLabProductionRunnerSelector {
  static WorkshopProductionExecutionRunner select({
    required bool enabled,
    required WorkshopProductionExecutionRunner historicalRunner,
    WorkshopAirLabInferenceBridge? bridge,
    WorkshopAirLabStagingRootResolver? stagingRootResolver,
    WorkshopAirLabTargetResolver? targetResolver,
    WorkshopAirLabExecutionApprovalResolver? approvalResolver,
    WorkshopAirLabProductionTaskMapper mapper =
        const WorkshopAirLabProductionTaskMapper(),
  }) {
    if (!enabled) return historicalRunner;

    if (bridge == null ||
        stagingRootResolver == null ||
        targetResolver == null ||
        approvalResolver == null) {
      throw const WorkshopAirLabProductionMappingException(
        'Enabled AIrLab production requires explicit bridge and resolvers.',
        code: 'airlab_production_configuration_incomplete',
      );
    }

    return WorkshopAirLabProductionExecutionRunner(
      handleSource: historicalRunner,
      bridge: bridge,
      stagingRootResolver: stagingRootResolver,
      targetResolver: targetResolver,
      approvalResolver: approvalResolver,
      mapper: mapper,
    );
  }
}

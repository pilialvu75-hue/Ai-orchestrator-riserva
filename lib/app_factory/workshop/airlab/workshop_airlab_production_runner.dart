import 'package:ai_orchestrator/app_factory/workshop/airlab/workshop_airlab_inference_bridge.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_execution_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_task_handle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';

typedef WorkshopAirLabProductionStagingRootResolver = String? Function(
  WorkshopProductionTaskHandle handle,
  WorkshopTaskContract task,
);

typedef WorkshopAirLabProductionTargetResolver = String? Function(
  WorkshopProductionTaskHandle handle,
  WorkshopTaskContract task,
);

typedef WorkshopAirLabProductionApprovalResolver = bool Function(
  WorkshopProductionTaskHandle handle,
  WorkshopTaskContract task,
);

/// Maps one already-prepared production task into the bounded contract accepted
/// by the opt-in AIrLab execution capability.
///
/// The mapper is intentionally fail-closed:
/// - only software projects are accepted in A6;
/// - writable scope must already be explicit in the authoritative project task
///   and/or request;
/// - when both scopes exist, only their exact overlap is writable;
/// - validation criteria and implementation instructions must be present.
final class WorkshopAirLabProductionTaskMapper {
  const WorkshopAirLabProductionTaskMapper();

  WorkshopTaskContract map({
    required WorkshopProjectPlan plan,
    required WorkshopProjectTask projectTask,
    required WorkshopRequest request,
  }) {
    if (plan.domain != WorkshopProjectDomain.software) {
      throw StateError(
        'AIrLab production A6 supports software-domain projects only.',
      );
    }

    final writableScope = _resolveWritableScope(
      projectTask.affectedPaths,
      request.targetFiles,
    );
    if (writableScope.isEmpty) {
      throw StateError(
        'AIrLab production requires an explicit writable file scope.',
      );
    }

    final validationCriteria = _uniqueNonEmpty(
      projectTask.validationCriteria.isNotEmpty
          ? projectTask.validationCriteria
          : plan.validationCriteria,
    );
    if (validationCriteria.isEmpty) {
      throw StateError(
        'AIrLab production requires explicit validation criteria.',
      );
    }

    final objective = projectTask.description.trim().isNotEmpty
        ? projectTask.description.trim()
        : plan.goal.trim();
    if (objective.isEmpty) {
      throw StateError(
        'AIrLab production requires a non-empty task objective.',
      );
    }

    final instructions = _uniqueNonEmpty(<String>[
      projectTask.description,
      ...plan.requirements,
    ]);
    if (instructions.isEmpty) {
      throw StateError(
        'AIrLab production requires explicit implementation instructions.',
      );
    }

    final constraints = _uniqueNonEmpty(<String>[
      ...plan.constraints,
      ...request.constraints,
      'Do not modify files outside the explicit AIrLab production scope.',
      'Do not commit, push, open a pull request, or apply real workspace changes automatically.',
    ]);

    return WorkshopTaskContract(
      id: projectTask.id,
      title: projectTask.title,
      objective: objective,
      kind: WorkshopTaskKind.codeModification,
      mode: WorkshopTaskMode.hybrid,
      preferredResource: WorkshopTaskResource.local,
      priority: _priority(projectTask.priority),
      status: WorkshopTaskStatus.ready,
      instructions: instructions,
      constraints: constraints,
      acceptanceCriteria: <WorkshopTaskAcceptanceCriterion>[
        for (var index = 0; index < validationCriteria.length; index++)
          WorkshopTaskAcceptanceCriterion(
            id: 'production_gate_${index + 1}',
            description: validationCriteria[index],
          ),
      ],
      fileScope: WorkshopTaskFileScope(
        allowed: writableScope,
      ),
      requiredCheckpoints: const <String>[
        'candidate_created',
        'review_completed',
        'validation_completed',
      ],
      dependsOn: List<String>.unmodifiable(projectTask.dependencies),
      tags: const <String>['airlab-production', 'a6'],
      metadata: <String, dynamic>{
        'productionProjectId': plan.id,
        'productionRequestId': request.id,
        'airlabProduction': true,
      },
    );
  }

  List<String> _resolveWritableScope(
    List<String> affectedPaths,
    List<String> targetFiles,
  ) {
    final affected = _uniqueNonEmpty(affectedPaths);
    final targets = _uniqueNonEmpty(targetFiles);

    if (affected.isEmpty) return targets;
    if (targets.isEmpty) return affected;

    final targetSet = targets.toSet();
    final overlap = affected
        .where(targetSet.contains)
        .toList(growable: false);

    if (overlap.isEmpty) {
      throw StateError(
        'AIrLab production task scope and request scope do not overlap.',
      );
    }
    return List<String>.unmodifiable(overlap);
  }

  List<String> _uniqueNonEmpty(Iterable<String> values) {
    final seen = <String>{};
    final result = <String>[];
    for (final value in values) {
      final normalized = value.trim();
      if (normalized.isEmpty || !seen.add(normalized)) continue;
      result.add(normalized);
    }
    return List<String>.unmodifiable(result);
  }

  WorkshopTaskPriority _priority(WorkshopProjectPriority priority) {
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
}

/// Explicit A6 production runner.
///
/// It delegates only prepared-handle lookup to the historical runner so there
/// remains exactly one authoritative Cantiere Project/Task/WorkspaceSession.
/// Execution itself goes through the already-existing AIrLab A5 bridge and ends
/// at Reviewer/validation. It never approves or applies real workspace changes.
final class WorkshopAirLabProductionExecutionRunner
    implements WorkshopProductionExecutionRunner {
  const WorkshopAirLabProductionExecutionRunner({
    required WorkshopProductionExecutionRunner historicalRunner,
    required WorkshopAirLabInferenceBridge bridge,
    required WorkshopAirLabProductionStagingRootResolver stagingRootResolver,
    required WorkshopAirLabProductionTargetResolver targetResolver,
    required WorkshopAirLabProductionApprovalResolver approvalResolver,
    this.mapper = const WorkshopAirLabProductionTaskMapper(),
  })  : _historicalRunner = historicalRunner,
        _bridge = bridge,
        _stagingRootResolver = stagingRootResolver,
        _targetResolver = targetResolver,
        _approvalResolver = approvalResolver;

  final WorkshopProductionExecutionRunner _historicalRunner;
  final WorkshopAirLabInferenceBridge _bridge;
  final WorkshopAirLabProductionStagingRootResolver _stagingRootResolver;
  final WorkshopAirLabProductionTargetResolver _targetResolver;
  final WorkshopAirLabProductionApprovalResolver _approvalResolver;
  final WorkshopAirLabProductionTaskMapper mapper;

  @override
  WorkshopProductionTaskHandle preparedHandle() =>
      _historicalRunner.preparedHandle();

  @override
  Future<WorkshopTaskInferenceResult> runPrepared({
    required WorkshopProductionTaskHandle handle,
    required CancellationToken cancellationToken,
    required bool isOffline,
  }) async {
    final projectTask = handle.plan.taskById(handle.taskId);
    if (projectTask == null) {
      throw StateError(
        'AIrLab production cannot resolve prepared task "${handle.taskId}".',
      );
    }

    final task = mapper.map(
      plan: handle.plan,
      projectTask: projectTask,
      request: handle.session.context.request,
    );

    final stagingRoot = _stagingRootResolver(handle, task)?.trim() ?? '';
    if (stagingRoot.isEmpty) {
      throw StateError(
        'AIrLab production requires an explicit controlled staging root.',
      );
    }

    final target = _targetResolver(handle, task)?.trim() ?? '';
    if (target.isEmpty) {
      throw StateError(
        'AIrLab production requires an explicit execution target.',
      );
    }

    final approvalGranted = _approvalResolver(handle, task);

    return _bridge.run(
      task: task,
      session: handle.session,
      stagingRoot: stagingRoot,
      networkAvailable: !isOffline,
      executionApprovalGranted: approvalGranted,
      isOffline: isOffline,
      projectId: handle.plan.id,
      target: target,
      cancellationToken: cancellationToken,
    );
  }
}

/// Opt-in selector used by composition roots.
///
/// Disabled means the exact historical runner instance is returned. Enabled
/// means an explicit AIrLab runner must be supplied; there is no silent
/// fallback between execution paths.
abstract final class WorkshopAirLabProductionRunnerSelector {
  static WorkshopProductionExecutionRunner select({
    required bool enabled,
    required WorkshopProductionExecutionRunner historicalRunner,
    WorkshopAirLabProductionExecutionRunner? airLabRunner,
  }) {
    if (!enabled) return historicalRunner;
    if (airLabRunner == null) {
      throw StateError(
        'AIrLab production is enabled but no explicit A6 runner was provided.',
      );
    }
    return airLabRunner;
  }
}

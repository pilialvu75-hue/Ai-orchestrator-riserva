import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_orchestrator.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';

typedef WorkshopDurableCapabilityResolver = String Function(
  WorkshopTaskContract task,
);

/// Read-only projection of the authoritative Cantiere task contract into the
/// durable scheduling overlay.
///
/// Instructions, file scope, budget, approval and mutable lifecycle authority
/// remain on [WorkshopTaskContract]. The durable task persists only the fields
/// needed to schedule/recover long-running work.
abstract final class WorkshopDurableTaskProjection {
  static WorkshopDurableTask fromContract(
    WorkshopTaskContract task, {
    required WorkshopDurableCapabilityResolver capabilityResolver,
    WorkshopDurableRetryPolicy retryPolicy =
        const WorkshopDurableRetryPolicy(),
    Duration timeout = const Duration(minutes: 30),
    DateTime? observedAt,
  }) {
    final capability = capabilityResolver(task).trim();
    if (capability.isEmpty) {
      throw StateError(
        'Durable scheduling requires a provider-neutral capability for task ' +
            task.id,
      );
    }

    return WorkshopDurableTask(
      taskId: task.id,
      dependencies: List<String>.unmodifiable(task.dependsOn),
      capability: capability,
      state: stateFromContract(task.status),
      retryPolicy: retryPolicy,
      timeout: timeout,
      completionCriterionIds: List<String>.unmodifiable(
        task.acceptanceCriteria
            .where((criterion) => criterion.required)
            .map((criterion) => criterion.id)
            .where((id) => id.trim().isNotEmpty),
      ),
      artifactIds: _checkpointArtifacts(task.checkpoint),
      updatedAt: (observedAt ?? task.updatedAt).toUtc(),
      blockedReasonCode: task.status == WorkshopTaskStatus.waitingApproval
          ? 'owner_approval_required'
          : null,
    );
  }

  static WorkshopDurableState stateFromContract(
    WorkshopTaskStatus status,
  ) {
    switch (status) {
      case WorkshopTaskStatus.planned:
        return WorkshopDurableState.planning;
      case WorkshopTaskStatus.ready:
      case WorkshopTaskStatus.reserved:
        return WorkshopDurableState.ready;
      case WorkshopTaskStatus.running:
        return WorkshopDurableState.running;
      case WorkshopTaskStatus.checkpointed:
        // A canonical checkpoint is resumable work, not proof that an external
        // operation is still in flight. WAITING_EXTERNAL is only entered when
        // an explicit durable external-wait descriptor exists.
        return WorkshopDurableState.ready;
      case WorkshopTaskStatus.waitingApproval:
        return WorkshopDurableState.blocked;
      case WorkshopTaskStatus.completed:
        return WorkshopDurableState.completed;
      case WorkshopTaskStatus.failed:
        return WorkshopDurableState.failed;
      case WorkshopTaskStatus.cancelled:
        return WorkshopDurableState.cancelled;
    }
  }

  static List<String> _checkpointArtifacts(
    WorkshopTaskCheckpoint? checkpoint,
  ) {
    final raw = checkpoint?.metadata['artifacts'];
    if (raw is! List) return const <String>[];

    final result = raw
        .map((item) => item?.toString().trim() ?? '')
        .where((item) => item.isNotEmpty)
        .toSet()
        .toList(growable: false)
      ..sort();
    return List<String>.unmodifiable(result);
  }
}

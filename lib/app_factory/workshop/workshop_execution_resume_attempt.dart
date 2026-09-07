import 'package:ai_orchestrator/app_factory/workshop/workshop_execution.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_resume_context.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_executor.dart';

/// Immutable handoff produced when one concrete Workshop execution attempt
/// gives way to another provider/model/account attempt.
///
/// [execution] carries the new attempt identity and runtime binding while
/// [resumeContext] carries the provider-neutral semantic state owned by the
/// authoritative Cantiere task/checkpoint.
final class WorkshopExecutionResumeAttempt {
  const WorkshopExecutionResumeAttempt({
    required this.execution,
    required this.resumeContext,
  });

  final WorkshopExecution execution;
  final WorkshopResumeContext resumeContext;
}

/// Creates the next concrete attempt of an existing Workshop execution from
/// the current authoritative Cantiere checkpoint.
///
/// This coordinator owns no workflow state. It only joins the already-existing
/// [WorkshopExecutionStore] attempt boundary with [WorkshopExecutionContinuity].
/// The task/checkpoint remains the single source of truth for what has been done
/// and what remains to do.
final class WorkshopExecutionResumeAttemptCoordinator {
  const WorkshopExecutionResumeAttemptCoordinator({
    required WorkshopExecutionStore executionStore,
  }) : _executionStore = executionStore;

  final WorkshopExecutionStore _executionStore;

  /// Persists the current authoritative checkpoint, creates a new attempt of
  /// the same stable execution, then builds the semantic context that the new
  /// provider/executor must receive.
  ///
  /// A resume without a Cantiere checkpoint is rejected: changing provider or
  /// model must never silently invent workflow state or restart from provider
  /// memory.
  Future<WorkshopExecutionResumeAttempt> beginNextAttempt({
    required WorkshopExecution execution,
    required WorkshopTaskContract task,
    WorkshopTaskExecutionResult? result,
    WorkshopTaskResource? resource,
    String? allocationId,
    String? executorId,
    String? providerId,
    String? modelId,
    String? accountId,
  }) async {
    if (task.checkpoint == null) {
      throw StateError(
        'Workshop execution ${execution.executionId} cannot resume task '
        '${task.id} without an authoritative Cantiere checkpoint.',
      );
    }

    final checkpointed = WorkshopExecutionContinuity.attachCheckpoint(
      execution: execution,
      task: task,
    );

    await _executionStore.save(checkpointed);

    final nextExecution = await _executionStore.beginNextAttempt(
      execution: checkpointed,
      resource: resource,
      allocationId: allocationId,
      executorId: executorId,
      providerId: providerId,
      modelId: modelId,
      accountId: accountId,
    );

    final resumeContext = WorkshopExecutionContinuity.buildResumeContext(
      execution: nextExecution,
      task: task,
      result: result,
    );

    return WorkshopExecutionResumeAttempt(
      execution: nextExecution,
      resumeContext: resumeContext,
    );
  }
}

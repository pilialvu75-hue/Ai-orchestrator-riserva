import 'package:ai_orchestrator/app_factory/workshop/workshop_project_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';

/// Runs the existing multi-role Workshop inference pipeline for a task that
/// has already been prepared by [WorkshopProjectExecutor].
///
/// This is the project-lifecycle bridge between a task id and its authoritative
/// workspace session. It never creates a second workspace, never approves or
/// applies changes, and never reads Assistant configuration, models, memory or
/// conversation state.
final class WorkshopPreparedTaskInferenceRunner {
  const WorkshopPreparedTaskInferenceRunner({
    required WorkshopProjectExecutor executor,
    required WorkshopTaskInferencePipeline pipeline,
  })  : _executor = executor,
        _pipeline = pipeline;

  final WorkshopProjectExecutor _executor;
  final WorkshopTaskInferencePipeline _pipeline;

  Future<WorkshopTaskInferenceResult> run({
    required String taskId,
    bool isOffline = true,
    CancellationToken? cancellationToken,
  }) async {
    final normalizedTaskId = taskId.trim();

    if (normalizedTaskId.isEmpty) {
      throw ArgumentError.value(
        taskId,
        'taskId',
        'Task id cannot be empty.',
      );
    }

    final session = _executor.sessionForTask(normalizedTaskId);

    if (session == null) {
      throw StateError(
        'No prepared WorkspaceSession exists for task "$normalizedTaskId".',
      );
    }

    return _pipeline.run(
      session: session,
      isOffline: isOffline,
      cancellationToken: cancellationToken,
    );
  }
}

import 'package:ai_orchestrator/app_factory/workshop/workshop_execution.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_executor.dart';

/// Provider-neutral semantic state required to resume one Workshop execution.
///
/// The Cantiere remains the only owner of project/task/workflow state. This
/// object is a read-only projection of the authoritative task/checkpoint state
/// for an executor that may never have seen previous attempts.
final class WorkshopResumeContext {
  const WorkshopResumeContext({
    required this.executionId,
    required this.attemptId,
    required this.projectId,
    required this.taskId,
    required this.sessionId,
    required this.objective,
    required this.phase,
    this.checkpointId,
    this.constraints = const <String>[],
    this.completedSteps = const <String>[],
    this.changedFiles = const <String>[],
    this.decisions = const <String>[],
    this.verified = const <String>[],
    this.remainingWork = const <String>[],
    this.artifacts = const <String>[],
    this.nextStep,
  });

  final String executionId;
  final String attemptId;
  final String projectId;
  final String taskId;
  final String sessionId;
  final String objective;
  final String phase;
  final String? checkpointId;
  final List<String> constraints;
  final List<String> completedSteps;
  final List<String> changedFiles;
  final List<String> decisions;
  final List<String> verified;
  final List<String> remainingWork;
  final List<String> artifacts;
  final String? nextStep;

  Map<String, dynamic> toMetadata() => <String, dynamic>{
        'executionId': executionId,
        'attemptId': attemptId,
        'projectId': projectId,
        'taskId': taskId,
        'sessionId': sessionId,
        'checkpointId': checkpointId,
        'phase': phase,
        'objective': objective,
        'constraints': constraints,
        'completedSteps': completedSteps,
        'changedFiles': changedFiles,
        'decisions': decisions,
        'verified': verified,
        'remainingWork': remainingWork,
        'artifacts': artifacts,
        'nextStep': nextStep,
      };
}

/// Bridges stable Workshop execution identity to the authoritative Cantiere
/// checkpoint without introducing a second Cloud-owned workflow state.
abstract final class WorkshopExecutionContinuity {
  /// Binds an execution to the current Cantiere checkpoint.
  ///
  /// Execution and attempt identities are preserved. Provider/model failover
  /// can later start a new attempt from the same checkpoint while keeping the
  /// same [WorkshopExecution.executionId].
  static WorkshopExecution attachCheckpoint({
    required WorkshopExecution execution,
    required WorkshopTaskContract task,
  }) {
    _ensureSameTask(execution, task);
    final checkpoint = task.checkpoint;
    if (checkpoint == null) return execution;

    return execution.copyWith(
      status: WorkshopExecutionStatus.checkpointed,
      checkpointId: checkpoint.id,
      resumePhase: checkpoint.phase,
    );
  }

  /// Builds a semantic resume projection from Cantiere-owned state.
  ///
  /// Semantic fields are read from the current checkpoint metadata using a
  /// small provider-neutral vocabulary. Unknown metadata remains owned by the
  /// Cantiere and is deliberately ignored here.
  static WorkshopResumeContext buildResumeContext({
    required WorkshopExecution execution,
    required WorkshopTaskContract task,
    WorkshopTaskExecutionResult? result,
  }) {
    _ensureSameTask(execution, task);
    final checkpoint = task.checkpoint;

    if (execution.checkpointId != null &&
        checkpoint != null &&
        execution.checkpointId != checkpoint.id) {
      throw StateError(
        'Execution checkpoint ${execution.checkpointId} is stale for task '
        '${task.id}; current checkpoint is ${checkpoint.id}.',
      );
    }

    final metadata = checkpoint?.metadata ?? const <String, dynamic>{};
    return WorkshopResumeContext(
      executionId: execution.executionId,
      attemptId: execution.attemptId,
      projectId: execution.projectId,
      taskId: task.id,
      sessionId: execution.sessionId,
      objective: task.objective,
      phase: checkpoint?.phase ?? execution.resumePhase ?? task.status.name,
      checkpointId: checkpoint?.id ?? execution.checkpointId,
      constraints: List<String>.unmodifiable(task.constraints),
      completedSteps: List<String>.unmodifiable(
        checkpoint?.completedSteps ?? const <String>[],
      ),
      changedFiles: List<String>.unmodifiable(
        checkpoint?.changedFiles ?? result?.changedFiles ?? const <String>[],
      ),
      decisions: _strings(metadata['decisions']),
      verified: _strings(metadata['verified']),
      remainingWork: _strings(metadata['remainingWork']),
      artifacts: List<String>.unmodifiable(
        <String>{
          ..._strings(metadata['artifacts']),
          ...?result?.artifacts,
        },
      ),
      nextStep: _string(metadata['nextStep']),
    );
  }

  static void _ensureSameTask(
    WorkshopExecution execution,
    WorkshopTaskContract task,
  ) {
    if (execution.taskId != task.id) {
      throw StateError(
        'Execution ${execution.executionId} belongs to task '
        '${execution.taskId}, not ${task.id}.',
      );
    }
  }

  static List<String> _strings(Object? value) {
    if (value is! Iterable) return const <String>[];
    return List<String>.unmodifiable(
      value
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty),
    );
  }

  static String? _string(Object? value) {
    final normalized = value?.toString().trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}

import 'package:ai_orchestrator/app_factory/workshop/workshop_execution.dart';

/// Read-only projection of the Cantiere-owned durable execution identity.
///
/// This deliberately excludes provider/model/account metadata, prompts,
/// workspace contents and credentials. External executors may use it only as
/// subordinate correlation evidence; it never transfers lifecycle authority.
final class WorkshopDurableExecutionIdentity {
  const WorkshopDurableExecutionIdentity({
    required this.projectId,
    required this.taskId,
    required this.executionId,
    required this.attemptId,
    this.checkpointId,
  });

  factory WorkshopDurableExecutionIdentity.fromExecution(
    WorkshopExecution execution,
  ) {
    return WorkshopDurableExecutionIdentity(
      projectId: execution.projectId,
      taskId: execution.taskId,
      executionId: execution.executionId,
      attemptId: execution.attemptId,
      checkpointId: execution.checkpointId,
    );
  }

  final String projectId;
  final String taskId;
  final String executionId;
  final String attemptId;
  final String? checkpointId;
}

import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_apply_approval_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_prepared_task_lifecycle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_lifecycle_bundle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';

/// Stable UI-facing handle for one prepared Cantiere production task.
///
/// It keeps the authoritative project plan, task id and WorkspaceSession
/// together so the UI cannot accidentally approve or apply a different task
/// from the one prepared by the dashboard.
final class WorkshopProductionTaskHandle {
  const WorkshopProductionTaskHandle({
    required this.plan,
    required this.taskId,
    required this.session,
  });

  final WorkshopProjectPlan plan;
  final String taskId;
  final WorkspaceSession session;
}

/// Thin coordinator that turns the production bundle into explicit UI steps.
///
/// It owns no runtime, downloader, workspace, storage, model configuration or
/// memory. Inference, owner decision and real apply remain distinct calls.
final class WorkshopProductionTaskCoordinator {
  const WorkshopProductionTaskCoordinator({
    required WorkshopProductionLifecycleBundle bundle,
  }) : _bundle = bundle;

  final WorkshopProductionLifecycleBundle _bundle;

  /// Starts a project and prepares exactly its next task without running model
  /// inference and without mutating the real workspace.
  Future<WorkshopProductionTaskHandle> startAndPrepare({
    required String title,
    required String instruction,
    List<String> requirements = const <String>[],
    List<String> constraints = const <String>[],
    List<String> technologies = const <String>[],
    List<String> deliverables = const <String>[],
    List<String> validationCriteria = const <String>[],
  }) async {
    final plan = _bundle.dashboardController.startProduction(
      title: title,
      instruction: instruction,
      requirements: requirements,
      constraints: constraints,
      technologies: technologies,
      deliverables: deliverables,
      validationCriteria: validationCriteria,
    );

    final session = await _bundle.dashboardController.prepareNextTask();
    final taskId = _bundle.dashboardController.state.activeTaskId?.trim();

    if (session == null || taskId == null || taskId.isEmpty) {
      throw StateError(
        'Workshop did not expose a prepared task after project preparation.',
      );
    }

    return WorkshopProductionTaskHandle(
      plan: plan,
      taskId: taskId,
      session: session,
    );
  }

  /// Runs Engineer -> Reviewer review -> Reviewer validation for the exact task
  /// represented by [handle]. No approval or real apply happens here.
  Future<WorkshopTaskInferenceResult> runPrepared({
    required WorkshopProductionTaskHandle handle,
    bool isOffline = true,
    CancellationToken? cancellationToken,
  }) {
    return _bundle.taskLifecycle.runPrepared(
      taskId: handle.taskId,
      isOffline: isOffline,
      cancellationToken: cancellationToken,
    );
  }

  /// Records the owner's explicit decision for the exact prepared task.
  WorkspaceSession decide({
    required WorkshopProductionTaskHandle handle,
    required WorkshopApplyDecision decision,
    String rejectionReason = 'Workshop changes rejected by owner.',
  }) {
    return _bundle.taskLifecycle.decide(
      taskId: handle.taskId,
      decision: decision,
      rejectionReason: rejectionReason,
    );
  }

  /// Applies only an explicitly approved task and advances its authoritative
  /// project plan after the real workspace mutation succeeds.
  Future<WorkspaceSession> applyApproved({
    required WorkshopProductionTaskHandle handle,
  }) {
    return _bundle.taskLifecycle.applyApprovedAndComplete(
      plan: handle.plan,
      taskId: handle.taskId,
    );
  }
}

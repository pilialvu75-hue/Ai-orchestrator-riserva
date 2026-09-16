import 'package:ai_orchestrator/app_factory/workshop/workshop_apply_approval_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_lifecycle_bundle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_task_handle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';

/// Guardrails for unattended Cantiere production.
///
/// Real workspace mutation is deliberately opt-in. Autonomous execution may
/// reason, review and validate with the default policy, but it cannot approve
/// or apply changes until the caller explicitly enables [allowRealWorkspaceApply].
final class WorkshopAutonomousProductionPolicy {
  const WorkshopAutonomousProductionPolicy({
    this.allowRealWorkspaceApply = false,
    this.requireFinalArtifact = true,
    this.maxTasks = 64,
  }) : assert(maxTasks > 0);

  /// Allows the coordinator to record an approval and apply already reviewed
  /// and validated changes to the authoritative real workspace.
  final bool allowRealWorkspaceApply;

  /// Treat a successful build without a detected artifact as a failed final
  /// production outcome.
  final bool requireFinalArtifact;

  /// Hard guard against malformed/cyclic project plans causing an unattended
  /// infinite production loop.
  final int maxTasks;
}

enum WorkshopAutonomousProductionStatus {
  completed,
  awaitingApproval,
  blockedByReview,
  blockedByValidation,
  stalled,
  taskLimitReached,
  buildFailed,
  cancelled,
}

/// Stable outcome of one autonomous production run.
final class WorkshopAutonomousProductionResult {
  const WorkshopAutonomousProductionResult({
    required this.status,
    required this.plan,
    required this.taskResults,
    this.buildResult,
    this.activeTaskId,
    this.message,
  });

  final WorkshopAutonomousProductionStatus status;
  final WorkshopProjectPlan plan;
  final List<WorkshopTaskInferenceResult> taskResults;
  final WorkshopBuildResult? buildResult;
  final String? activeTaskId;
  final String? message;

  bool get succeeded =>
      status == WorkshopAutonomousProductionStatus.completed &&
      buildResult?.succeeded == true;
}

/// End-to-end Cantiere coordinator built strictly on the existing production
/// boundaries.
///
/// It does not duplicate inference, workspace mutation or build logic. Instead
/// it composes the authoritative flow already owned by:
///
///   WorkshopProductionTaskCoordinator
///     -> preflight / Engineer / Reviewer / validation
///     -> approval gate
///     -> real workspace apply
///     -> next project task
///     -> Build Lab
///
/// A task is never auto-applied unless review + validation succeeded and the
/// explicit autonomous policy allows real workspace mutation.
final class WorkshopAutonomousProductionCoordinator {
  WorkshopAutonomousProductionCoordinator({
    required WorkshopProductionLifecycleBundle bundle,
    this.policy = const WorkshopAutonomousProductionPolicy(),
  })  : _bundle = bundle,
        _tasks = WorkshopProductionTaskCoordinator(bundle: bundle);

  final WorkshopProductionLifecycleBundle _bundle;
  final WorkshopProductionTaskCoordinator _tasks;
  final WorkshopAutonomousProductionPolicy policy;

  /// Starts a new Cantiere project and advances it as far as the configured
  /// autonomous policy safely permits.
  Future<WorkshopAutonomousProductionResult> runNewProduction({
    required String title,
    required String instruction,
    required WorkshopBuildTarget target,
    List<String> requirements = const <String>[],
    List<String> constraints = const <String>[],
    List<String> technologies = const <String>[],
    List<String> deliverables = const <String>[],
    List<String> validationCriteria = const <String>[],
    bool isOffline = false,
    WorkshopBuildExecutionMode buildMode =
        WorkshopBuildExecutionMode.automatic,
    bool runTests = true,
    bool runAnalyzer = true,
    bool runFormatter = true,
    bool cleanBuild = false,
    List<String> buildArguments = const <String>[],
    CancellationToken? cancellationToken,
  }) async {
    final handle = await _tasks.startAndPrepare(
      title: title,
      instruction: instruction,
      requirements: requirements,
      constraints: constraints,
      technologies: technologies,
      deliverables: deliverables,
      validationCriteria: validationCriteria,
    );

    return _runFromHandle(
      handle: handle,
      target: target,
      isOffline: isOffline,
      buildMode: buildMode,
      runTests: runTests,
      runAnalyzer: runAnalyzer,
      runFormatter: runFormatter,
      cleanBuild: cleanBuild,
      buildArguments: buildArguments,
      cancellationToken: cancellationToken,
    );
  }

  /// Continues the exact task already prepared by the shared production
  /// dashboard. This is useful after process/UI recovery without inventing a
  /// second WorkspaceSession.
  Future<WorkshopAutonomousProductionResult> continuePreparedProduction({
    required WorkshopBuildTarget target,
    bool isOffline = false,
    WorkshopBuildExecutionMode buildMode =
        WorkshopBuildExecutionMode.automatic,
    bool runTests = true,
    bool runAnalyzer = true,
    bool runFormatter = true,
    bool cleanBuild = false,
    List<String> buildArguments = const <String>[],
    CancellationToken? cancellationToken,
  }) {
    return _runFromHandle(
      handle: _tasks.preparedHandle(),
      target: target,
      isOffline: isOffline,
      buildMode: buildMode,
      runTests: runTests,
      runAnalyzer: runAnalyzer,
      runFormatter: runFormatter,
      cleanBuild: cleanBuild,
      buildArguments: buildArguments,
      cancellationToken: cancellationToken,
    );
  }

  Future<WorkshopAutonomousProductionResult> _runFromHandle({
    required WorkshopProductionTaskHandle handle,
    required WorkshopBuildTarget target,
    required bool isOffline,
    required WorkshopBuildExecutionMode buildMode,
    required bool runTests,
    required bool runAnalyzer,
    required bool runFormatter,
    required bool cleanBuild,
    required List<String> buildArguments,
    CancellationToken? cancellationToken,
  }) async {
    final taskResults = <WorkshopTaskInferenceResult>[];
    var currentHandle = handle;

    for (var taskIndex = 0; taskIndex < policy.maxTasks; taskIndex++) {
      if (cancellationToken?.isCancelled == true) {
        return _result(
          status: WorkshopAutonomousProductionStatus.cancelled,
          plan: currentHandle.plan,
          taskResults: taskResults,
          activeTaskId: currentHandle.taskId,
          message: 'Autonomous Workshop production was cancelled.',
        );
      }

      final inference = await _tasks.runPrepared(
        handle: currentHandle,
        isOffline: isOffline,
        cancellationToken: cancellationToken,
      );
      taskResults.add(inference);

      if (!inference.review.approved) {
        return _result(
          status: WorkshopAutonomousProductionStatus.blockedByReview,
          plan: currentHandle.plan,
          taskResults: taskResults,
          activeTaskId: currentHandle.taskId,
          message: 'Reviewer rejected the prepared Workshop task.',
        );
      }

      if (inference.validation?.valid != true) {
        return _result(
          status: WorkshopAutonomousProductionStatus.blockedByValidation,
          plan: currentHandle.plan,
          taskResults: taskResults,
          activeTaskId: currentHandle.taskId,
          message: 'Workshop validation did not approve the prepared task.',
        );
      }

      if (!policy.allowRealWorkspaceApply) {
        return _result(
          status: WorkshopAutonomousProductionStatus.awaitingApproval,
          plan: currentHandle.plan,
          taskResults: taskResults,
          activeTaskId: currentHandle.taskId,
          message: 'Task is reviewed and validated but autonomous real-workspace '
              'apply is disabled by policy.',
        );
      }

      _tasks.decide(
        handle: currentHandle,
        decision: WorkshopApplyDecision.approve,
      );
      await _tasks.applyApproved(handle: currentHandle);

      if (cancellationToken?.isCancelled == true) {
        return _result(
          status: WorkshopAutonomousProductionStatus.cancelled,
          plan: currentHandle.plan,
          taskResults: taskResults,
          message: 'Autonomous Workshop production was cancelled after a safe '
              'task boundary.',
        );
      }

      final nextSession = await _bundle.dashboardController.prepareNextTask();

      if (nextSession == null) {
        if (!currentHandle.plan.isComplete) {
          return _result(
            status: WorkshopAutonomousProductionStatus.stalled,
            plan: currentHandle.plan,
            taskResults: taskResults,
            message: 'No executable Workshop task remains, but the project is '
                'not complete.',
          );
        }
        break;
      }

      final nextTaskId =
          _bundle.dashboardController.state.activeTaskId?.trim();
      if (nextTaskId == null || nextTaskId.isEmpty) {
        return _result(
          status: WorkshopAutonomousProductionStatus.stalled,
          plan: currentHandle.plan,
          taskResults: taskResults,
          message: 'Workshop prepared a session without an authoritative task id.',
        );
      }

      currentHandle = WorkshopProductionTaskHandle(
        plan: currentHandle.plan,
        taskId: nextTaskId,
        session: nextSession,
      );
    }

    if (!currentHandle.plan.isComplete) {
      return _result(
        status: WorkshopAutonomousProductionStatus.taskLimitReached,
        plan: currentHandle.plan,
        taskResults: taskResults,
        activeTaskId: _bundle.dashboardController.state.activeTaskId,
        message: 'Autonomous Workshop task limit reached before project completion.',
      );
    }

    if (cancellationToken?.isCancelled == true) {
      return _result(
        status: WorkshopAutonomousProductionStatus.cancelled,
        plan: currentHandle.plan,
        taskResults: taskResults,
        message: 'Autonomous Workshop production was cancelled before build.',
      );
    }

    final effectiveBuildMode = isOffline
        ? WorkshopBuildExecutionMode.offlineLocal
        : buildMode;

    final buildResult = await _tasks.buildWorkspace(
      target: target,
      mode: effectiveBuildMode,
      runTests: runTests,
      runAnalyzer: runAnalyzer,
      runFormatter: runFormatter,
      cleanBuild: cleanBuild,
      arguments: buildArguments,
    );

    if (!buildResult.succeeded ||
        (policy.requireFinalArtifact && !buildResult.hasArtifact)) {
      return _result(
        status: WorkshopAutonomousProductionStatus.buildFailed,
        plan: currentHandle.plan,
        taskResults: taskResults,
        buildResult: buildResult,
        message: buildResult.message ??
            'Workshop final build did not produce a valid artifact.',
      );
    }

    return _result(
      status: WorkshopAutonomousProductionStatus.completed,
      plan: currentHandle.plan,
      taskResults: taskResults,
      buildResult: buildResult,
      message: 'Workshop production completed with a validated build artifact.',
    );
  }

  WorkshopAutonomousProductionResult _result({
    required WorkshopAutonomousProductionStatus status,
    required WorkshopProjectPlan plan,
    required List<WorkshopTaskInferenceResult> taskResults,
    WorkshopBuildResult? buildResult,
    String? activeTaskId,
    String? message,
  }) {
    return WorkshopAutonomousProductionResult(
      status: status,
      plan: plan,
      taskResults: List<WorkshopTaskInferenceResult>.unmodifiable(taskResults),
      buildResult: buildResult,
      activeTaskId: activeTaskId,
      message: message,
    );
  }
}

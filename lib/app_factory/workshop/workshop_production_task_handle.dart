import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_apply_approval_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_prepared_task_lifecycle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_lifecycle_bundle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_resume_context.dart';
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

  /// Recovers the stable handle for the task already prepared by the dashboard.
  ///
  /// This is the UI bridge used when the existing conversational page performs
  /// startProduction() and prepareNextTask() first. It only looks up the plan
  /// and WorkspaceSession already owned by the shared production bundle; it
  /// never creates a second session or mutates the real workspace.
  WorkshopProductionTaskHandle preparedHandle() {
    final state = _bundle.dashboardController.state;
    final requestId = state.requestId?.trim();
    final taskId = state.activeTaskId?.trim();

    if (requestId == null || requestId.isEmpty) {
      throw StateError(
        'Workshop has no active production request for a prepared task.',
      );
    }

    if (taskId == null || taskId.isEmpty) {
      throw StateError(
        'Workshop has no prepared task to expose to the production UI.',
      );
    }

    final plan = _bundle.dashboardController.engine.planOf(requestId);
    final session = _bundle.projectExecutor.sessionForTask(taskId);

    if (plan == null) {
      throw StateError(
        'Workshop has no project plan for active request "$requestId".',
      );
    }

    if (session == null) {
      throw StateError(
        'Workshop has no WorkspaceSession for prepared task "$taskId".',
      );
    }

    return WorkshopProductionTaskHandle(
      plan: plan,
      taskId: taskId,
      session: session,
    );
  }

  /// Runs the complete Cantiere model chain for the exact task represented by
  /// [handle]: Orchestrator -> Architect -> Engineer -> Reviewer review ->
  /// Reviewer validation. No approval or real apply happens here.
  ///
  /// If preflight selected verified reusable production knowledge and a safe
  /// source snapshot exists for that asset, the snapshot is staged into the
  /// same authoritative VirtualWorkspace before Engineer inference. Existing
  /// project files are never overwritten by this automatic reuse staging.
  ///
  /// A missing or stale optional snapshot is treated as a cache miss: the
  /// normal AI path continues instead of blocking production.
  ///
  /// The production UI follows the configured Local / Cloud / Hybrid runtime
  /// by default. Offline execution remains available only when a caller
  /// explicitly requests it.
  Future<WorkshopTaskInferenceResult> runPrepared({
    required WorkshopProductionTaskHandle handle,
    bool isOffline = false,
    CancellationToken? cancellationToken,
  }) async {
    final preflight = await _bundle.preflight.run(
      request: handle.session.context.request,
      isOffline: isOffline,
      cancellationToken: cancellationToken,
    );

    await _stageReusableSourceIfAvailable(
      handle: handle,
      assetId: preflight.reusedAsset?.id,
    );

    return _bundle.taskLifecycle.runPrepared(
      taskId: handle.taskId,
      preflight: preflight,
      isOffline: isOffline,
      cancellationToken: cancellationToken,
    );
  }

  /// Resumes the complete prepared-task model chain for the exact production
  /// handle from Cantiere-owned semantic state.
  ///
  /// The handle remains the authoritative plan/task/session bridge. The resume
  /// context is forwarded to the existing prepared-task lifecycle and does not
  /// create or own a second task, workspace, checkpoint, execution or provider
  /// state. A bounded preflight is still regenerated from the same request so
  /// Orchestrator/Architect guidance stays aligned with the prepared session.
  /// Reuse staging is idempotent for already-present workspace paths.
  Future<WorkshopTaskInferenceResult> runPreparedWithResumeContext({
    required WorkshopProductionTaskHandle handle,
    required WorkshopResumeContext resumeContext,
    bool isOffline = false,
    CancellationToken? cancellationToken,
  }) async {
    if (resumeContext.taskId.trim() != handle.taskId.trim()) {
      throw StateError(
        'Workshop resume context belongs to task "${resumeContext.taskId}", '
        'not production handle task "${handle.taskId}".',
      );
    }

    final authoritativeSession =
        _bundle.projectExecutor.sessionForTask(handle.taskId);
    if (!identical(authoritativeSession, handle.session)) {
      throw StateError(
        'Workshop production handle no longer references the authoritative '
        'WorkspaceSession for task "${handle.taskId}".',
      );
    }

    final preflight = await _bundle.preflight.run(
      request: handle.session.context.request,
      isOffline: isOffline,
      cancellationToken: cancellationToken,
    );

    await _stageReusableSourceIfAvailable(
      handle: handle,
      assetId: preflight.reusedAsset?.id,
    );

    return _bundle.taskLifecycle.runPreparedWithResumeContext(
      taskId: handle.taskId,
      resumeContext: resumeContext,
      preflight: preflight,
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
  ///
  /// The active Dashboard task is verified before the mutating apply. Once
  /// apply + plan completion have succeeded through the existing guarded
  /// lifecycle, the Dashboard completes the same task again only at the project
  /// bookkeeping boundary. [WorkshopProjectExecutor.completeTask] is
  /// intentionally idempotent for a completed session, so this performs no
  /// second workspace write: it synchronizes WorkshopEngine stage/result and
  /// the observable Dashboard progress with the authoritative completed plan.
  Future<WorkspaceSession> applyApproved({
    required WorkshopProductionTaskHandle handle,
  }) async {
    final activeTaskId =
        _bundle.dashboardController.state.activeTaskId?.trim();

    if (activeTaskId != handle.taskId) {
      throw StateError(
        'Workshop dashboard active task changed before applying '
        '"${handle.taskId}".',
      );
    }

    final session = await _bundle.taskLifecycle.applyApprovedAndComplete(
      plan: handle.plan,
      taskId: handle.taskId,
    );

    _bundle.dashboardController.completeActiveTask();

    return session;
  }

  /// Runs the existing Build Lab against the exact real workspace bound to
  /// this production bundle, but only after the authoritative Cantiere project
  /// has completed and no prepared task remains active.
  ///
  /// This method does not discover another project path and never consults
  /// Assistant state. It is only the guarded production bridge from the
  /// authoritative Cantiere workspace into the already-existing
  /// build/test/validation layer.
  Future<WorkshopBuildResult> buildWorkspace({
    required WorkshopBuildTarget target,
    WorkshopBuildExecutionMode mode = WorkshopBuildExecutionMode.automatic,
    bool runTests = true,
    bool runAnalyzer = true,
    bool runFormatter = true,
    bool cleanBuild = false,
    List<String> arguments = const <String>[],
  }) {
    final workspaceRootPath = _bundle.workspaceRootPath?.trim();

    if (workspaceRootPath == null || workspaceRootPath.isEmpty) {
      throw StateError(
        'Workshop production bundle has no authoritative workspace path.',
      );
    }

    final dashboardState = _bundle.dashboardController.state;
    final requestId = dashboardState.requestId?.trim();

    if (requestId == null || requestId.isEmpty) {
      throw StateError(
        'Workshop final build requires an active production project.',
      );
    }

    final plan = _bundle.dashboardController.engine.planOf(requestId);

    if (plan == null) {
      throw StateError(
        'Workshop has no authoritative project plan for "$requestId".',
      );
    }

    final activeTaskId = dashboardState.activeTaskId?.trim();
    final allTasksCompleted = plan.tasks.every((task) => task.completed);

    if (!plan.isComplete ||
        !allTasksCompleted ||
        (activeTaskId != null && activeTaskId.isNotEmpty)) {
      throw StateError(
        'Workshop final build is allowed only after every project task has '
        'completed and no active task remains.',
      );
    }

    return _bundle.dashboardController.buildProject(
      projectPath: workspaceRootPath,
      target: target,
      mode: mode,
      runTests: runTests,
      runAnalyzer: runAnalyzer,
      runFormatter: runFormatter,
      cleanBuild: cleanBuild,
      arguments: arguments,
    );
  }

  Future<void> _stageReusableSourceIfAvailable({
    required WorkshopProductionTaskHandle handle,
    required String? assetId,
  }) async {
    final normalizedAssetId = assetId?.trim();
    if (normalizedAssetId == null || normalizedAssetId.isEmpty) {
      return;
    }

    final snapshot =
        _bundle.reuseSourceSnapshots?.forAsset(normalizedAssetId);
    if (snapshot == null) {
      return;
    }

    try {
      await _bundle.reuseSourceSnapshotService.stageInto(
        snapshot: snapshot,
        session: handle.session,
      );
    } catch (_) {
      // Reuse is an optimization, never a new availability dependency.
      // A stale/missing local snapshot falls back to the historical AI path.
    }
  }
}

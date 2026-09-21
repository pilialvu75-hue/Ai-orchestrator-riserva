import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_dispatcher.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_execution_pipeline.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_resource_allocator.dart';

import 'workshop_airlab_client.dart';
import 'workshop_airlab_contract.dart';
import 'workshop_airlab_staging_materializer.dart';
import 'workshop_airlab_task_executor.dart';
import 'workshop_airlab_workspace_promoter.dart';

/// Availability projection exposed by the opt-in AIrLab capability.
///
/// The snapshot can be passed directly to the existing Workshop allocator/guard
/// pipeline. It never grants repository authority by itself.
final class WorkshopAirLabCapabilityProbe {
  const WorkshopAirLabCapabilityProbe({
    required this.probe,
    required this.resource,
  });

  final WorkshopAirLabProbe probe;
  final WorkshopResourceSnapshot resource;

  bool get isAvailable => probe.isAvailable && resource.isUsable;
}

/// Result of one explicitly requested AIrLab capability run.
///
/// A successful [promotion] means only staging -> VirtualWorkspace review.
/// It never means that the real workspace was approved or applied.
final class WorkshopAirLabCapabilityRunResult {
  const WorkshopAirLabCapabilityRunResult({
    required this.availability,
    required this.execution,
    this.promotion,
  });

  final WorkshopAirLabCapabilityProbe availability;
  final WorkshopTaskExecutionResult execution;
  final WorkshopAirLabWorkspacePromotionResult? promotion;

  bool get promotedToReview => promotion != null;
}

/// Opt-in composition boundary for AIrLab inside the Cantiere.
///
/// This class composes the already certified pieces:
///
///   AIrLab client
///      -> task executor
///      -> existing allocator / guard / dispatcher pipeline
///      -> controlled staging
///      -> VirtualWorkspace promotion
///
/// It is intentionally NOT registered in the production routing by default.
/// The caller must explicitly:
/// - construct it with [enabled] = true;
/// - provide an assigned staging root;
/// - grant execution approval when required by the normal Execution Guard.
///
/// Even after a successful run, real workspace mutation still requires the
/// existing WorkspaceSession review -> validation -> approveApply -> apply path.
final class WorkshopAirLabCapability {
  WorkshopAirLabCapability({
    required this.enabled,
    required WorkshopAirLabClient client,
    required WorkshopAirLabStagingMaterializer stagingMaterializer,
    required WorkshopAirLabStagingReader stagingReader,
    this.networkRequired = false,
    this.displayName = 'AIrLab',
    this.estimatedLatencyMs = 0,
    WorkshopAirLabWorkspacePromoter promoter =
        const WorkshopAirLabWorkspacePromoter(),
  })  : _client = client,
        _stagingReader = stagingReader,
        _promoter = promoter {
    _executor = WorkshopAirLabTaskExecutor(
      client: _client,
      stagingMaterializer: stagingMaterializer,
    );
    _dispatcher = WorkshopTaskDispatcher(
      executors: <WorkshopTaskExecutor>[_executor],
    );
    _pipeline = WorkshopTaskExecutionPipeline(
      dispatcher: _dispatcher,
    );
  }

  static const String providerId = 'airlab';

  final bool enabled;
  final bool networkRequired;
  final String displayName;
  final int estimatedLatencyMs;

  final WorkshopAirLabClient _client;
  final WorkshopAirLabStagingReader _stagingReader;
  final WorkshopAirLabWorkspacePromoter _promoter;

  late final WorkshopAirLabTaskExecutor _executor;
  late final WorkshopTaskDispatcher _dispatcher;
  late final WorkshopTaskExecutionPipeline _pipeline;

  WorkshopTaskExecutionPipeline get pipeline => _pipeline;
  WorkshopTaskDispatcher get dispatcher => _dispatcher;
  WorkshopAirLabTaskExecutor get executor => _executor;

  /// Probes AIrLab and projects the result as one ordinary Workshop resource.
  ///
  /// Disabled capability state is represented explicitly and causes no network
  /// call. No fallback resource is registered here.
  Future<WorkshopAirLabCapabilityProbe> probe() async {
    if (!enabled) {
      return _probeFrom(
        const WorkshopAirLabProbe(
          availability: WorkshopAirLabAvailability.unavailable,
          reason: 'AIrLab capability is disabled.',
        ),
      );
    }

    final probe = await _executor.refreshAvailability();
    return _probeFrom(probe);
  }

  /// Executes one authorized task and, only when AIrLab produced controlled
  /// staging, promotes that staging into the supplied VirtualWorkspace review.
  ///
  /// This method never calls WorkspaceSession.approveApply() or apply().
  Future<WorkshopAirLabCapabilityRunResult> run({
    required WorkshopTaskContract task,
    required WorkspaceSession session,
    required String stagingRoot,
    bool networkAvailable = true,
    bool executionApprovalGranted = false,
    String? projectId,
    String? target,
    WorkshopTaskExecutionProgressCallback? onProgress,
  }) async {
    if (!enabled) {
      final availability = _probeFrom(
        const WorkshopAirLabProbe(
          availability: WorkshopAirLabAvailability.unavailable,
          reason: 'AIrLab capability is disabled.',
        ),
      );
      return WorkshopAirLabCapabilityRunResult(
        availability: availability,
        execution: _failure(
          task: task,
          code: 'airlab_disabled',
          message: 'AIrLab execution is opt-in and is currently disabled.',
        ),
      );
    }

    final normalizedStagingRoot = stagingRoot.trim();
    if (normalizedStagingRoot.isEmpty) {
      final availability = _probeFrom(
        const WorkshopAirLabProbe(
          availability: WorkshopAirLabAvailability.unavailable,
          reason: 'No controlled Cantiere staging root was assigned.',
        ),
      );
      return WorkshopAirLabCapabilityRunResult(
        availability: availability,
        execution: _failure(
          task: task,
          code: 'staging_root_missing',
          message: 'AIrLab requires an explicit controlled staging root.',
        ),
      );
    }

    if (networkRequired && !networkAvailable) {
      final availability = _probeFrom(
        const WorkshopAirLabProbe(
          availability: WorkshopAirLabAvailability.unavailable,
          reason: 'AIrLab endpoint requires network access.',
        ),
      );
      return WorkshopAirLabCapabilityRunResult(
        availability: availability,
        execution: _failure(
          task: task,
          code: 'network_unavailable',
          message: 'AIrLab endpoint requires network access.',
        ),
      );
    }

    final availability = await probe();
    if (!availability.isAvailable) {
      return WorkshopAirLabCapabilityRunResult(
        availability: availability,
        execution: _failure(
          task: task,
          code: 'airlab_unavailable',
          message: availability.probe.reason ??
              'AIrLab is not currently available.',
        ),
      );
    }

    final metadata = <String, dynamic>{
      if (projectId != null && projectId.trim().isNotEmpty)
        'projectId': projectId.trim(),
      if (target != null && target.trim().isNotEmpty)
        'target': target.trim(),
      'airlabCapability': true,
    };

    final execution = await _pipeline.execute(
      task: task,
      resources: <WorkshopResourceSnapshot>[availability.resource],
      context: WorkshopTaskExecutionContext(
        stagingRoot: normalizedStagingRoot,
        networkAvailable: networkAvailable,
        metadata: metadata,
      ),
      networkAvailable: networkAvailable,
      approvalGranted: executionApprovalGranted,
      onProgress: onProgress,
    );

    final promotionRequired =
        execution.metadata['promotionRequired'] == true;

    if (!promotionRequired) {
      return WorkshopAirLabCapabilityRunResult(
        availability: availability,
        execution: execution,
      );
    }

    if (!execution.requiresApproval) {
      return WorkshopAirLabCapabilityRunResult(
        availability: availability,
        execution: _failure(
          task: task,
          code: 'promotion_state_invalid',
          message:
              'AIrLab requested promotion without an approval-gated staging result.',
        ),
      );
    }

    try {
      final promotion = await _promoter.promote(
        session: session,
        executionResult: execution,
        stagingRoot: normalizedStagingRoot,
        reader: _stagingReader,
      );

      return WorkshopAirLabCapabilityRunResult(
        availability: availability,
        execution: execution,
        promotion: promotion,
      );
    } on WorkshopAirLabPromotionException catch (error) {
      return WorkshopAirLabCapabilityRunResult(
        availability: availability,
        execution: _failure(
          task: task,
          code: error.code,
          message: 'AIrLab promotion rejected: ${error.message}',
          path: error.path,
        ),
      );
    }
  }

  WorkshopAirLabCapabilityProbe _probeFrom(
    WorkshopAirLabProbe probe,
  ) {
    final available = enabled && probe.isAvailable;
    return WorkshopAirLabCapabilityProbe(
      probe: probe,
      resource: WorkshopResourceSnapshot(
        resource: WorkshopTaskResource.local,
        providerId: providerId,
        displayName: displayName,
        health: available
            ? WorkshopResourceHealth.available
            : WorkshopResourceHealth.unavailable,
        available: available,
        networkRequired: networkRequired,
        availableCredits: 0,
        estimatedCreditsPerTask: 0,
        estimatedLatencyMs: estimatedLatencyMs,
        capabilities: const <WorkshopResourceCapability>[
          WorkshopResourceCapability.planning,
          WorkshopResourceCapability.reasoning,
          WorkshopResourceCapability.codeGeneration,
          WorkshopResourceCapability.codeReview,
          WorkshopResourceCapability.testing,
          WorkshopResourceCapability.staticAnalysis,
          WorkshopResourceCapability.documentation,
          WorkshopResourceCapability.multimodal,
        ],
        metadata: <String, dynamic>{
          'airlab': true,
          'enabled': enabled,
          'availability': probe.availability.name,
          if (probe.engineId != null) 'engineId': probe.engineId,
        },
      ),
    );
  }

  WorkshopTaskExecutionResult _failure({
    required WorkshopTaskContract task,
    required String code,
    required String message,
    String? path,
  }) {
    return WorkshopTaskExecutionResult(
      taskId: task.id,
      status: WorkshopTaskStatus.failed,
      message: message,
      metadata: <String, dynamic>{
        'executor': providerId,
        'code': code,
        'repositoryModified': false,
        if (path != null) 'path': path,
      },
    );
  }
}

import 'workshop_resource_execution_bridge.dart';
import 'workshop_task_contract.dart';
import 'workshop_task_dispatcher.dart';
import 'workshop_task_execution_guard.dart';
import 'workshop_task_executor.dart';
import 'workshop_task_resource_allocator.dart';

/// Pipeline operativa del Cantiere.
///
/// Coordina esclusivamente i passaggi già definiti dai componenti
/// sottostanti:
///
///   Task
///     ↓
///   Resource Execution Bridge
///     ↓
///   Execution Guard
///     ↓
///   Dispatcher
///     ↓
///   Executor
///
/// La pipeline NON:
///
/// - pianifica task;
/// - sceglie autonomamente provider alternativi;
/// - modifica il repository;
/// - bypassa il Guard;
/// - aumenta il budget;
/// - esegue direttamente provider AI;
/// - decide autonomamente di passare da Local a Cloud.
///
/// È il coordinatore tecnico della singola esecuzione.
final class WorkshopTaskExecutionPipeline {
  WorkshopTaskExecutionPipeline({
    WorkshopResourceExecutionBridge? resourceBridge,
    WorkshopTaskExecutionGuard? executionGuard,
    WorkshopTaskDispatcher? dispatcher,
  })  : _resourceBridge =
            resourceBridge ??
                WorkshopResourceExecutionBridge(),
        _executionGuard =
            executionGuard ??
                const WorkshopTaskExecutionGuard(),
        _dispatcher =
            dispatcher ??
                WorkshopTaskDispatcher();

  final WorkshopResourceExecutionBridge
      _resourceBridge;

  final WorkshopTaskExecutionGuard
      _executionGuard;

  final WorkshopTaskDispatcher
      _dispatcher;

  WorkshopResourceExecutionBridge
      get resourceBridge =>
          _resourceBridge;

  WorkshopTaskExecutionGuard
      get executionGuard =>
          _executionGuard;

  WorkshopTaskDispatcher
      get dispatcher =>
          _dispatcher;

  /// Esegue la pipeline completa.
  ///
  /// Il metodo restituisce sempre un risultato esplicito:
  ///
  /// - completed;
  /// - failed;
  /// - waitingApproval;
  /// - cancelled;
  /// - altro stato previsto dal contratto.
  ///
  /// Nessuna fase successiva viene eseguita se quella precedente
  /// non produce una decisione valida.
  Future<WorkshopTaskExecutionResult> execute({
    required WorkshopTaskContract task,
    required List<WorkshopResourceSnapshot> resources,
    WorkshopTaskExecutionContext context =
        const WorkshopTaskExecutionContext(),
    bool networkAvailable = true,
    bool approvalGranted = false,
    WorkshopTaskExecutionProgressCallback?
        onProgress,
  }) async {
    final allocationDecision =
        _resourceBridge.prepare(
      task: task,
      resources: resources,
      networkAvailable:
          networkAvailable,
    );

    if (!allocationDecision.authorized ||
        allocationDecision.allocation == null) {
      return WorkshopTaskExecutionResult(
        taskId: task.id,
        status: WorkshopTaskStatus.failed,
        message:
            allocationDecision.reason ??
                'Resource allocation was not authorized.',
        metadata: <String, dynamic>{
          'pipelinePhase': 'allocation',
          'resource':
              allocationDecision
                  .allocation
                  ?.resource
                  .name,
          'providerId':
              allocationDecision
                  .allocation
                  ?.providerId,
        },
      );
    }

    final allocation =
        allocationDecision.allocation!;

    final resourceSnapshot =
        _findMatchingResource(
      allocation: allocation,
      resources: resources,
    );

    if (resourceSnapshot == null) {
      return WorkshopTaskExecutionResult(
        taskId: task.id,
        status: WorkshopTaskStatus.failed,
        message:
            'The allocated resource snapshot could not be found.',
        metadata: <String, dynamic>{
          'pipelinePhase': 'resource-resolution',
          'resource':
              allocation.resource.name,
          'providerId':
              allocation.providerId,
        },
      );
    }

    final guardDecision =
        _executionGuard.check(
      task: task,
      allocation: allocation,
      resource: resourceSnapshot,
      networkAvailable:
          networkAvailable,
      approvalGranted:
          approvalGranted,
    );

    if (!guardDecision.isAllowed) {
      final status =
          guardDecision.blockReason ==
                  WorkshopTaskExecutionBlockReason
                      .approvalRequired
              ? WorkshopTaskStatus.waitingApproval
              : WorkshopTaskStatus.failed;

      return WorkshopTaskExecutionResult(
        taskId: task.id,
        status: status,
        message:
            guardDecision.message,
        metadata: <String, dynamic>{
          'pipelinePhase': 'execution-guard',
          'blockReason':
              guardDecision
                  .blockReason
                  ?.name,
          'resource':
              guardDecision.resource?.name,
          'providerId':
              guardDecision.providerId,
        },
      );
    }

    final enrichedContext =
        WorkshopTaskExecutionContext(
      stagingRoot:
          context.stagingRoot,
      workingDirectory:
          context.workingDirectory,
      networkAvailable:
          context.networkAvailable &&
              networkAvailable,
      metadata: <String, dynamic>{
        ...context.metadata,
        'pipeline': 'workshop-task-execution',
        'resource':
            allocation.resource.name,
        'providerId':
            allocation.providerId,
        'allocationReason':
            allocation.reason,
        'estimatedCredits':
            allocation.estimatedCredits,
        'estimatedLatencyMs':
            allocation.estimatedLatencyMs,
      },
    );

    final result =
        await _dispatcher.dispatch(
      task: task,
      guardDecision:
          guardDecision,
      context: enrichedContext,
      onProgress:
          onProgress,
    );

    return _attachPipelineMetadata(
      task: task,
      allocation: allocation,
      result: result,
    );
  }

  /// Variante che privilegia esplicitamente una risorsa.
  ///
  /// Utile per HYBRID quando il livello superiore ha già deciso
  /// che una determinata risorsa/provider deve essere preferita,
  /// senza però bypassare allocator, budget e Guard.
  Future<WorkshopTaskExecutionResult>
      executeWithPreference({
    required WorkshopTaskContract task,
    required List<WorkshopResourceSnapshot> resources,
    required WorkshopTaskResource
        preferredResource,
    WorkshopTaskExecutionContext context =
        const WorkshopTaskExecutionContext(),
    bool networkAvailable = true,
    bool approvalGranted = false,
    WorkshopTaskExecutionProgressCallback?
        onProgress,
  }) async {
    final allocationDecision =
        _resourceBridge.prepareWithPreference(
      task: task,
      resources: resources,
      preferredResource:
          preferredResource,
      networkAvailable:
          networkAvailable,
    );

    if (!allocationDecision.authorized ||
        allocationDecision.allocation == null) {
      return WorkshopTaskExecutionResult(
        taskId: task.id,
        status: WorkshopTaskStatus.failed,
        message:
            allocationDecision.reason ??
                'Preferred resource allocation was not authorized.',
        metadata: <String, dynamic>{
          'pipelinePhase': 'allocation',
          'preferredResource':
              preferredResource.name,
        },
      );
    }

    return _executeFromAllocation(
      task: task,
      allocation:
          allocationDecision.allocation!,
      resources: resources,
      context: context,
      networkAvailable:
          networkAvailable,
      approvalGranted:
          approvalGranted,
      onProgress:
          onProgress,
    );
  }

  Future<WorkshopTaskExecutionResult>
      _executeFromAllocation({
    required WorkshopTaskContract task,
    required WorkshopResourceAllocation
        allocation,
    required List<WorkshopResourceSnapshot>
        resources,
    required WorkshopTaskExecutionContext
        context,
    required bool networkAvailable,
    required bool approvalGranted,
    WorkshopTaskExecutionProgressCallback?
        onProgress,
  }) async {
    final resourceSnapshot =
        _findMatchingResource(
      allocation: allocation,
      resources: resources,
    );

    if (resourceSnapshot == null) {
      return WorkshopTaskExecutionResult(
        taskId: task.id,
        status: WorkshopTaskStatus.failed,
        message:
            'The allocated resource snapshot could not be found.',
        metadata: <String, dynamic>{
          'pipelinePhase':
              'resource-resolution',
          'resource':
              allocation.resource.name,
          'providerId':
              allocation.providerId,
        },
      );
    }

    final guardDecision =
        _executionGuard.check(
      task: task,
      allocation: allocation,
      resource: resourceSnapshot,
      networkAvailable:
          networkAvailable,
      approvalGranted:
          approvalGranted,
    );

    if (!guardDecision.isAllowed) {
      final status =
          guardDecision.blockReason ==
                  WorkshopTaskExecutionBlockReason
                      .approvalRequired
              ? WorkshopTaskStatus.waitingApproval
              : WorkshopTaskStatus.failed;

      return WorkshopTaskExecutionResult(
        taskId: task.id,
        status: status,
        message:
            guardDecision.message,
        metadata: <String, dynamic>{
          'pipelinePhase':
              'execution-guard',
          'blockReason':
              guardDecision
                  .blockReason
                  ?.name,
          'resource':
              guardDecision.resource?.name,
          'providerId':
              guardDecision.providerId,
        },
      );
    }

    final enrichedContext =
        WorkshopTaskExecutionContext(
      stagingRoot:
          context.stagingRoot,
      workingDirectory:
          context.workingDirectory,
      networkAvailable:
          context.networkAvailable &&
              networkAvailable,
      metadata: <String, dynamic>{
        ...context.metadata,
        'pipeline':
            'workshop-task-execution',
        'resource':
            allocation.resource.name,
        'providerId':
            allocation.providerId,
        'allocationReason':
            allocation.reason,
        'estimatedCredits':
            allocation.estimatedCredits,
        'estimatedLatencyMs':
            allocation.estimatedLatencyMs,
      },
    );

    final result =
        await _dispatcher.dispatch(
      task: task,
      guardDecision:
          guardDecision,
      context: enrichedContext,
      onProgress:
          onProgress,
    );

    return _attachPipelineMetadata(
      task: task,
      allocation: allocation,
      result: result,
    );
  }

  /// Cerca lo snapshot corrispondente alla decisione dell'allocator.
  ///
  /// La corrispondenza providerId viene preferita.
  /// Se la decisione non specifica un provider, basta la risorsa.
  WorkshopResourceSnapshot?
      _findMatchingResource({
    required WorkshopResourceAllocation
        allocation,
    required List<WorkshopResourceSnapshot>
        resources,
  }) {
    if (allocation.providerId != null) {
      for (final resource in resources) {
        if (resource.resource ==
                allocation.resource &&
            resource.providerId ==
                allocation.providerId) {
          return resource;
        }
      }
    }

    for (final resource in resources) {
      if (resource.resource ==
          allocation.resource) {
        return resource;
      }
    }

    return null;
  }

  /// Aggiunge informazioni diagnostiche della pipeline
  /// senza alterare il risultato prodotto dal Dispatcher.
  WorkshopTaskExecutionResult
      _attachPipelineMetadata({
    required WorkshopTaskContract task,
    required WorkshopResourceAllocation
        allocation,
    required WorkshopTaskExecutionResult
        result,
  }) {
    return WorkshopTaskExecutionResult(
      taskId: task.id,
      status: result.status,
      message: result.message,
      checkpoint: result.checkpoint,
      changedFiles: result.changedFiles,
      artifacts: result.artifacts,
      metadata: <String, dynamic>{
        ...result.metadata,
        'pipelinePhase':
            'dispatcher',
        'allocatedResource':
            allocation.resource.name,
        'allocatedProvider':
            allocation.providerId,
        'allocationReason':
            allocation.reason,
        'estimatedCredits':
            allocation.estimatedCredits,
        'estimatedLatencyMs':
            allocation.estimatedLatencyMs,
      },
    );
  }

  /// Diagnostica completa della pipeline.
  Map<String, dynamic> diagnostics() {
    return <String, dynamic>{
      'allocation':
          _resourceBridge
              .allocationController
              .diagnostics(),
      'executors':
          _dispatcher.diagnostics(),
    };
  }
}

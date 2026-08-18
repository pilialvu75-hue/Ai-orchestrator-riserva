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
///
/// I contratti di Context, Result, Executor e ProgressCallback
/// sono definiti esclusivamente in workshop_task_executor.dart.
/// La Pipeline li utilizza senza ridefinirli.
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
  /// Ordine rigoroso:
  ///
  /// 1. allocation;
  /// 2. resource resolution;
  /// 3. execution guard;
  /// 4. context enrichment;
  /// 5. dispatcher;
  /// 6. result validation;
  /// 7. pipeline metadata.
  ///
  /// Nessuna fase successiva viene eseguita se quella precedente
  /// non produce una decisione valida.
  ///
  /// La Pipeline non effettua fallback autonomi.
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
    if (task.id.trim().isEmpty) {
      return _failure(
        task: task,
        message: 'Task id cannot be empty.',
        metadata: <String, dynamic>{
          'pipelinePhase': 'validation',
        },
      );
    }

    final allocationDecision =
        _resourceBridge.prepare(
      task: task,
      resources: resources,
      networkAvailable:
          networkAvailable,
    );

    if (!allocationDecision.authorized ||
        allocationDecision.allocation == null) {
      return _failure(
        task: task,
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
          'fallbackResource':
              allocationDecision
                  .fallbackResource
                  ?.name,
        },
      );
    }

    final allocation =
        allocationDecision.allocation!;

    if (allocation.taskId != task.id) {
      return _failure(
        task: task,
        message:
            'Resource allocation does not belong to the current task.',
        metadata: <String, dynamic>{
          'pipelinePhase': 'allocation-validation',
          'expectedTaskId': task.id,
          'allocatedTaskId': allocation.taskId,
          'resource':
              allocation.resource.name,
          'providerId':
              allocation.providerId,
        },
      );
    }

    return _executeFromAllocation(
      task: task,
      allocation: allocation,
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

  /// Variante che privilegia esplicitamente una risorsa.
  ///
  /// Utile soprattutto in HYBRID quando il livello superiore
  /// ha già deciso quale risorsa preferire.
  ///
  /// La preferenza NON bypassa:
  ///
  /// - allocator;
  /// - budget;
  /// - resource validation;
  /// - Execution Guard;
  /// - approval policy.
  ///
  /// Se la risorsa preferita non è disponibile, la decisione
  /// viene lasciata al Resource Allocation Controller secondo
  /// la sua normale politica.
  Future<WorkshopTaskExecutionResult>
      executeWithPreference({
    required WorkshopTaskContract task,
    required List<WorkshopResourceSnapshot>
        resources,
    required WorkshopTaskResource
        preferredResource,
    WorkshopTaskExecutionContext context =
        const WorkshopTaskExecutionContext(),
    bool networkAvailable = true,
    bool approvalGranted = false,
    WorkshopTaskExecutionProgressCallback?
        onProgress,
  }) async {
    if (task.id.trim().isEmpty) {
      return _failure(
        task: task,
        message: 'Task id cannot be empty.',
        metadata: <String, dynamic>{
          'pipelinePhase': 'validation',
          'preferredResource':
              preferredResource.name,
        },
      );
    }

    final allocationDecision =
        _resourceBridge
            .prepareWithPreference(
      task: task,
      resources: resources,
      preferredResource:
          preferredResource,
      networkAvailable:
          networkAvailable,
    );

    if (!allocationDecision.authorized ||
        allocationDecision.allocation == null) {
      return _failure(
        task: task,
        message:
            allocationDecision.reason ??
                'Preferred resource allocation was not authorized.',
        metadata: <String, dynamic>{
          'pipelinePhase': 'allocation',
          'preferredResource':
              preferredResource.name,
          'fallbackResource':
              allocationDecision
                  .fallbackResource
                  ?.name,
        },
      );
    }

    final allocation =
        allocationDecision.allocation!;

    if (allocation.taskId != task.id) {
      return _failure(
        task: task,
        message:
            'Resource allocation does not belong to the current task.',
        metadata: <String, dynamic>{
          'pipelinePhase': 'allocation-validation',
          'expectedTaskId': task.id,
          'allocatedTaskId': allocation.taskId,
          'preferredResource':
              preferredResource.name,
          'allocatedResource':
              allocation.resource.name,
        },
      );
    }

    return _executeFromAllocation(
      task: task,
      allocation: allocation,
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

  /// Esegue la pipeline a partire da una decisione di allocazione
  /// già validata.
  ///
  /// Questo metodo centralizza la seconda metà della pipeline
  /// evitando duplicazioni tra execute() e executeWithPreference().
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
      return _failure(
        task: task,
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
              guardDecision
                  .resource
                  ?.name,
          'providerId':
              guardDecision.providerId,
        },
      );
    }

    final enrichedContext =
        _buildContext(
      context: context,
      allocation: allocation,
      networkAvailable:
          networkAvailable,
    );

    final result =
        await _dispatcher.dispatch(
      task: task,
      guardDecision:
          guardDecision,
      context:
          enrichedContext,
      onProgress:
          onProgress,
    );

    return _normalizeResult(
      task: task,
      allocation: allocation,
      result: result,
    );
  }

  /// Costruisce il Context senza modificare quello originale.
  ///
  /// Questo mantiene la Pipeline immutabile dal punto di vista
  /// del chiamante e permette di aggiungere esclusivamente
  /// informazioni infrastrutturali.
  WorkshopTaskExecutionContext
      _buildContext({
    required WorkshopTaskExecutionContext
        context,
    required WorkshopResourceAllocation
        allocation,
    required bool networkAvailable,
  }) {
    return WorkshopTaskExecutionContext(
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
        'requiresNetwork':
            allocation.requiresNetwork,
        'isLocal':
            allocation.isLocal,
        'isHybrid':
            allocation.isHybrid,
        'isGithub':
            allocation.isGithub,
      },
    );
  }

  /// Cerca lo snapshot corrispondente alla decisione dell'allocator.
  ///
  /// Se è presente un providerId viene cercata prima
  /// la corrispondenza resource + provider.
  ///
  /// Solo quando il provider non è specificato viene utilizzata
  /// la prima risorsa compatibile.
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

      return null;
    }

    for (final resource in resources) {
      if (resource.resource ==
          allocation.resource) {
        return resource;
      }
    }

    return null;
  }

  /// Valida il risultato prodotto dal Dispatcher.
  ///
  /// Un executor non deve poter restituire silenziosamente
  /// un risultato appartenente a una task diversa.
  WorkshopTaskExecutionResult
      _normalizeResult({
    required WorkshopTaskContract task,
    required WorkshopResourceAllocation
        allocation,
    required WorkshopTaskExecutionResult
        result,
  }) {
    if (result.taskId != task.id) {
      return _failure(
        task: task,
        message:
            'Executor returned a result for a different task.',
        metadata: <String, dynamic>{
          'pipelinePhase':
              'result-validation',
          'expectedTaskId':
              task.id,
          'returnedTaskId':
              result.taskId,
          'resource':
              allocation.resource.name,
          'providerId':
              allocation.providerId,
        },
      );
    }

    return WorkshopTaskExecutionResult(
      taskId: result.taskId,
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
        'requiresNetwork':
            allocation.requiresNetwork,
      },
    );
  }

  WorkshopTaskExecutionResult _failure({
    required WorkshopTaskContract task,
    required String message,
    Map<String, dynamic> metadata =
        const <String, dynamic>{},
  }) {
    return WorkshopTaskExecutionResult(
      taskId: task.id,
      status:
          WorkshopTaskStatus.failed,
      message: message,
      metadata: metadata,
    );
  }

  /// Diagnostica completa della Pipeline.
  ///
  /// Pensata per:
  ///
  /// - Developer Mode;
  /// - forensic logs;
  /// - diagnostica del Cantiere;
  /// - future sincronizzazione con il sito privato;
  /// - supervisione da parte di Hannibal.
  Map<String, dynamic> diagnostics() {
    return <String, dynamic>{
      'pipeline': 'workshop-task-execution',
      'allocation':
          _resourceBridge
              .diagnostics(),
      'dispatcher':
          _dispatcher.diagnostics(),
      'executorCount':
          _dispatcher.executorCount,
    };
  }
}

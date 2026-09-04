import 'package:ai_orchestrator/app_factory/workshop/workshop_resource_allocation_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_resource_allocator.dart';

/// Risultato pronto per essere consegnato al Dispatcher.
///
/// La bridge non esegue la task:
/// prepara solamente una decisione coerente e verificabile.
final class WorkshopResourceExecutionDecision {
  const WorkshopResourceExecutionDecision({
    required this.authorized,
    required this.taskId,
    this.allocation,
    this.reason,
    this.fallbackResource,
    this.reserved = false,
  });

  final bool authorized;
  final String taskId;
  final WorkshopResourceAllocation? allocation;
  final String? reason;
  final WorkshopTaskResource? fallbackResource;
  final bool reserved;

  bool get readyForExecution =>
      authorized &&
      allocation != null;

  bool get requiresNetwork =>
      allocation?.requiresNetwork ?? false;

  bool get isLocal =>
      allocation?.isLocal ?? false;

  bool get isGithub =>
      allocation?.isGithub ?? false;

  bool get isHybrid =>
      allocation?.isHybrid ?? false;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'authorized': authorized,
      'taskId': taskId,
      'allocation': allocation?.toJson(),
      'reason': reason,
      'fallbackResource':
          fallbackResource?.name,
      'reserved': reserved,
      'readyForExecution':
          readyForExecution,
      'requiresNetwork':
          requiresNetwork,
    };
  }
}

/// Ponte tra allocazione e Dispatch.
///
/// Flusso:
///
///     WorkshopTaskContract
///             ↓
///     ResourceExecutionBridge
///             ↓
///     AllocationController
///             ↓
///     BudgetController
///             ↓
///     ExecutionDecision
///             ↓
///     WorkshopTaskDispatcher
///
/// La bridge NON:
///
/// - chiama LLM;
/// - modifica file;
/// - esegue GitHub Agent;
/// - avvia GitHub Actions;
/// - esegue build;
/// - consuma direttamente crediti.
///
/// Il Dispatcher rimane responsabile dell'esecuzione.
final class WorkshopResourceExecutionBridge {
  WorkshopResourceExecutionBridge({
    WorkshopResourceAllocationController?
        allocationController,
  }) : _allocationController =
            allocationController ??
                WorkshopResourceAllocationController();

  final WorkshopResourceAllocationController
      _allocationController;

  WorkshopResourceAllocationController
      get allocationController =>
          _allocationController;

  /// Prepara una task per l'esecuzione.
  ///
  /// Non riserva automaticamente crediti.
  ///
  /// Questo metodo è utile quando il Dispatcher vuole prima
  /// conoscere la decisione e decidere successivamente
  /// quando effettuare la prenotazione.
  WorkshopResourceExecutionDecision prepare({
    required WorkshopTaskContract task,
    required List<WorkshopResourceSnapshot> resources,
    bool networkAvailable = true,
  }) {
    final decision =
        _allocationController.allocate(
      task: task,
      resources: resources,
      networkAvailable:
          networkAvailable,
    );

    if (!decision.authorized ||
        decision.allocation == null) {
      return WorkshopResourceExecutionDecision(
        authorized: false,
        taskId: task.id,
        allocation:
            decision.allocation,
        reason:
            decision.reason ??
                'No execution resource was authorized.',
        fallbackResource:
            decision.fallbackResource,
      );
    }

    return WorkshopResourceExecutionDecision(
      authorized: true,
      taskId: task.id,
      allocation:
          decision.allocation,
    );
  }

  /// Prepara una task dando priorità a una risorsa specifica.
  ///
  /// Se quella risorsa non è disponibile o non è autorizzabile,
  /// il controller può ricadere sulla normale strategia
  /// di allocazione.
  WorkshopResourceExecutionDecision prepareWithPreference({
    required WorkshopTaskContract task,
    required List<WorkshopResourceSnapshot> resources,
    required WorkshopTaskResource preferredResource,
    bool networkAvailable = true,
  }) {
    final decision =
        _allocationController
            .allocateWithPreference(
      task: task,
      resources: resources,
      preferredResource:
          preferredResource,
      networkAvailable:
          networkAvailable,
    );

    if (!decision.authorized ||
        decision.allocation == null) {
      return WorkshopResourceExecutionDecision(
        authorized: false,
        taskId: task.id,
        allocation:
            decision.allocation,
        reason:
            decision.reason ??
                'The preferred resource and its fallbacks '
                'could not be authorized.',
        fallbackResource:
            decision.fallbackResource,
      );
    }

    return WorkshopResourceExecutionDecision(
      authorized: true,
      taskId: task.id,
      allocation:
          decision.allocation,
    );
  }

  /// Prepara e riserva il budget della task.
  ///
  /// La riserva è logica: non significa che il provider
  /// abbia già consumato crediti.
  ///
  /// Questo è il metodo che il Dispatcher potrà utilizzare
  /// quando sarà pronto a passare dalla pianificazione
  /// all'esecuzione.
  WorkshopResourceExecutionDecision
      prepareAndReserve({
    required WorkshopTaskContract task,
    required List<WorkshopResourceSnapshot> resources,
    bool networkAvailable = true,
  }) {
    final decision =
        _allocationController.allocate(
      task: task,
      resources: resources,
      networkAvailable:
          networkAvailable,
    );

    if (!decision.authorized ||
        decision.allocation == null) {
      return WorkshopResourceExecutionDecision(
        authorized: false,
        taskId: task.id,
        allocation:
            decision.allocation,
        reason:
            decision.reason ??
                'No execution resource was authorized.',
        fallbackResource:
            decision.fallbackResource,
      );
    }

    final reserved =
        _allocationController
            .tryReserveForTask(
      task: task,
      decision: decision,
    );

    if (!reserved) {
      return WorkshopResourceExecutionDecision(
        authorized: false,
        taskId: task.id,
        allocation:
            decision.allocation,
        reason:
            'The resource was authorized but its budget '
            'could not be reserved.',
        fallbackResource:
            decision.fallbackResource,
      );
    }

    return WorkshopResourceExecutionDecision(
      authorized: true,
      taskId: task.id,
      allocation:
          decision.allocation,
      reserved: true,
    );
  }

  /// Prepara e riserva usando una risorsa preferita.
  WorkshopResourceExecutionDecision
      prepareAndReserveWithPreference({
    required WorkshopTaskContract task,
    required List<WorkshopResourceSnapshot> resources,
    required WorkshopTaskResource preferredResource,
    bool networkAvailable = true,
  }) {
    final decision =
        _allocationController
            .allocateWithPreference(
      task: task,
      resources: resources,
      preferredResource:
          preferredResource,
      networkAvailable:
          networkAvailable,
    );

    if (!decision.authorized ||
        decision.allocation == null) {
      return WorkshopResourceExecutionDecision(
        authorized: false,
        taskId: task.id,
        allocation:
            decision.allocation,
        reason:
            decision.reason ??
                'No authorized resource was found.',
        fallbackResource:
            decision.fallbackResource,
      );
    }

    final reserved =
        _allocationController
            .tryReserveForTask(
      task: task,
      decision: decision,
    );

    if (!reserved) {
      return WorkshopResourceExecutionDecision(
        authorized: false,
        taskId: task.id,
        allocation:
            decision.allocation,
        reason:
            'The selected resource could not reserve '
            'the required execution budget.',
        fallbackResource:
            decision.fallbackResource,
      );
    }

    return WorkshopResourceExecutionDecision(
      authorized: true,
      taskId: task.id,
      allocation:
          decision.allocation,
      reserved: true,
    );
  }

  /// Rilascia una prenotazione precedente.
  void release({
    required WorkshopTaskResource resource,
    required double credits,
  }) {
    _allocationController.release(
      resource: resource,
      credits: credits,
    );
  }

  /// Aggiorna il budget conosciuto di una risorsa.
  void updateBudget({
    required WorkshopTaskResource resource,
    required double availableCredits,
    double? minimumReserveCredits,
  }) {
    _allocationController.updateBudget(
      resource: resource,
      availableCredits:
          availableCredits,
      minimumReserveCredits:
          minimumReserveCredits,
    );
  }

  /// Diagnostica della bridge e dei livelli sottostanti.
  Map<String, dynamic> diagnostics() {
    return <String, dynamic>{
      'allocationController':
          _allocationController.diagnostics(),
    };
  }
}

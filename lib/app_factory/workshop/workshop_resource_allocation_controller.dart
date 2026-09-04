import 'package:ai_orchestrator/app_factory/workshop/workshop_budget_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_resource_allocator.dart';

/// Risultato finale del tentativo di allocazione.
///
/// L'allocator decide la risorsa in base alle capacità e allo stato.
/// Il Budget Controller verifica invece che quella scelta sia
/// economicamente autorizzabile.
///
/// Questo oggetto unisce le due decisioni senza eseguire la task.
final class WorkshopResourceAllocationDecision {
  const WorkshopResourceAllocationDecision({
    required this.authorized,
    required this.taskId,
    this.allocation,
    this.reason,
    this.fallbackResource,
  });

  final bool authorized;
  final String taskId;
  final WorkshopResourceAllocation? allocation;
  final String? reason;
  final WorkshopTaskResource? fallbackResource;

  bool get hasAllocation =>
      allocation != null;

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
    };
  }
}

/// Controller che collega:
///
///     Resource Allocator
///             ↓
///     Budget Controller
///             ↓
///     Execution Dispatcher
///
/// Il controller NON:
///
/// - esegue task;
/// - chiama provider AI;
/// - modifica file;
/// - avvia GitHub Actions;
/// - consuma direttamente crediti.
///
/// Si limita a combinare:
///
/// 1. disponibilità tecnica della risorsa;
/// 2. policy;
/// 3. budget;
/// 4. fallback.
///
/// Questo è particolarmente importante per HYBRID:
/// un provider cloud non viene utilizzato semplicemente perché
/// esiste; deve essere tecnicamente adatto e finanziariamente
/// autorizzato.
final class WorkshopResourceAllocationController {
  WorkshopResourceAllocationController({
    WorkshopTaskResourceAllocator? allocator,
    WorkshopBudgetController? budgetController,
  })  : _allocator =
            allocator ??
                const WorkshopTaskResourceAllocator(),
        _budgetController =
            budgetController ??
                WorkshopBudgetController();

  final WorkshopTaskResourceAllocator _allocator;
  final WorkshopBudgetController _budgetController;

  WorkshopTaskResourceAllocator get allocator =>
      _allocator;

  WorkshopBudgetController get budgetController =>
      _budgetController;

  /// Tenta di produrre una decisione completa.
  ///
  /// La risorsa viene prima selezionata tecnicamente,
  /// poi sottoposta al controllo economico.
  WorkshopResourceAllocationDecision allocate({
    required WorkshopTaskContract task,
    required List<WorkshopResourceSnapshot> resources,
    bool networkAvailable = true,
  }) {
    final allocation = _allocator.allocate(
      task: task,
      resources: resources,
      networkAvailable: networkAvailable,
    );

    if (allocation == null) {
      return WorkshopResourceAllocationDecision(
        authorized: false,
        taskId: task.id,
        reason:
            'No technically suitable execution resource is available.',
      );
    }

    final budgetDecision =
        _budgetController.evaluate(
      task: task,
      resource: allocation.resource,
    );

    if (budgetDecision.authorized) {
      return WorkshopResourceAllocationDecision(
        authorized: true,
        taskId: task.id,
        allocation: allocation,
      );
    }

    return WorkshopResourceAllocationDecision(
      authorized: false,
      taskId: task.id,
      allocation: allocation,
      reason:  
      budgetDecision.reason,
  fallbackResource: 
      budgetDecision.fallbackResource,
   );
  }

  /// Tenta di allocare direttamente una risorsa preferita.
  ///
  /// Se la risorsa preferita non è autorizzabile, viene cercata
  /// una soluzione alternativa attraverso la normale policy
  /// dell'allocator e del Budget Controller.
  WorkshopResourceAllocationDecision
      allocateWithPreference({
    required WorkshopTaskContract task,
    required List<WorkshopResourceSnapshot>
        resources,
    required WorkshopTaskResource
        preferredResource,
    bool networkAvailable = true,
  }) {
    final preferred =
        resources.where(
      (snapshot) =>
          snapshot.resource ==
          preferredResource,
    );

    if (preferred.isNotEmpty) {
      final preferredAllocation =
          _allocator.allocate(
        task: task,
        resources:
            preferred.toList(
          growable: false,
        ),
        networkAvailable:
            networkAvailable,
      );

      if (preferredAllocation != null) {
        final budgetDecision =
            _budgetController.evaluate(
          task: task,
          resource:
              preferredAllocation.resource,
        );

        if (budgetDecision.authorized) {
          return WorkshopResourceAllocationDecision(
            authorized: true,
            taskId: task.id,
            allocation:
                preferredAllocation,
          );
        }

        return WorkshopResourceAllocationDecision(
          authorized: false,
          taskId: task.id,
          allocation:
              preferredAllocation,
          reason: budgetDecision.reason,
          fallbackResource:
              budgetDecision.fallbackResource,
        );
      }
    }

    // La preferenza non è disponibile o non è tecnicamente
    // utilizzabile: lasciamo che allocator + budget policy
    // trovino la migliore alternativa.
    return allocate(
      task: task,
      resources: resources,
      networkAvailable:
          networkAvailable,
    );
  }

  /// Prenota logicamente il budget della risorsa scelta
  /// mantenendo il contratto originale della task.
  ///
  /// Non effettua alcun consumo presso il provider.
  ///
  /// È intenzionalmente l'unica API pubblica di prenotazione:
  /// non è sicuro ricostruire una WorkshopTaskContract partendo
  /// dalla sola allocation.
  bool tryReserveForTask({
    required WorkshopTaskContract task,
    required WorkshopResourceAllocationDecision
        decision,
  }) {
    final allocation =
        decision.allocation;

    if (!decision.authorized ||
        allocation == null) {
      return false;
    }

    // La risorsa Local non richiede un consumo
    // di crediti remoti.
    if (allocation.resource ==
        WorkshopTaskResource.local) {
      return true;
    }

    return _budgetController.tryReserve(
      task: task,
      resource: allocation.resource,
    );
  }

  /// Rilascia una prenotazione.
  void release({
    required WorkshopTaskResource resource,
    required double credits,
  }) {
    _budgetController.release(
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
    _budgetController.updateBudget(
      resource: resource,
      availableCredits:
          availableCredits,
      minimumReserveCredits:
          minimumReserveCredits,
    );
  }

  /// Restituisce una fotografia diagnostica.
  ///
  /// L'Allocator non espone un proprio metodo diagnostics(),
  /// quindi il controller registra esclusivamente informazioni
  /// realmente disponibili dal suo contratto pubblico.
  Map<String, dynamic> diagnostics() {
    return <String, dynamic>{
      'allocator': <String, dynamic>{
        'policy': <String, dynamic>{
          'preferLocal':
              _allocator.policy.preferLocal,
          'allowDegradedResources':
              _allocator
                  .policy
                  .allowDegradedResources,
          'allowHybridFallback':
              _allocator
                  .policy
                  .allowHybridFallback,
          'allowGithubAgent':
              _allocator
                  .policy
                  .allowGithubAgent,
          'allowGithubActions':
              _allocator
                  .policy
                  .allowGithubActions,
          'minimumCreditReserve':
              _allocator
                  .policy
                  .minimumCreditReserve,
        },
      },
      'budget':
          _budgetController.diagnostics(),
    };
  }
}

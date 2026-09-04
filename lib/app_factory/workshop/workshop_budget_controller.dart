import 'package:ai_orchestrator/app_factory/workshop/workshop_execution_budget_manager.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_resource_budget_policy.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';

/// Punto centrale di coordinamento tra:
///
/// - Resource Budget Policy;
/// - Execution Budget Manager.
///
/// Il controller NON esegue task e NON chiama provider.
///
/// Il suo compito è determinare:
///
/// 1. quali risorse sono ammesse dalla policy;
/// 2. quali sono economicamente disponibili;
/// 3. quale risorsa può essere utilizzata;
/// 4. quale fallback può essere tentato.
///
/// Flusso:
///
///     Task
///       ↓
///     BudgetController
///       ├── Policy
///       └── BudgetManager
///       ↓
///     risorsa autorizzata / fallback
///
/// Il Resource Allocator rimane responsabile della selezione
/// tecnica basata sulle capacità reali delle risorse.
final class WorkshopBudgetController {
  WorkshopBudgetController({
    WorkshopResourceBudgetPolicy policy =
        const WorkshopResourceBudgetPolicy(),
    WorkshopExecutionBudgetManager? budgetManager,
  })  : _policy = policy,
        _budgetManager =
            budgetManager ??
                WorkshopExecutionBudgetManager();

  final WorkshopResourceBudgetPolicy _policy;
  final WorkshopExecutionBudgetManager _budgetManager;

  WorkshopResourceBudgetPolicy get policy => _policy;

  WorkshopExecutionBudgetManager get budgetManager =>
      _budgetManager;

  /// Valuta una singola risorsa.
  ///
  /// La policy viene verificata prima del budget.
  WorkshopExecutionBudgetDecision evaluate({
    required WorkshopTaskContract task,
    required WorkshopTaskResource resource,
  }) {
    if (!_policy.canSelectAutomatically(
      task: task,
      resource: resource,
    )) {
      return WorkshopExecutionBudgetDecision(
        authorized: false,
        resource: resource,
        estimatedCredits:
            task.budget.estimatedCredits.toDouble(),
        usableCredits: 0,
        reason:
            'The resource is not allowed by the current budget policy.',
        fallbackResource:
            _findFallback(
          task: task,
          excluded: resource,
        ),
      );
    }

    final decision = _budgetManager.evaluate(
      task: task,
      resource: resource,
    );

    if (decision.authorized) {
      return decision;
    }

    return WorkshopExecutionBudgetDecision(
      authorized: false,
      resource: resource,
      estimatedCredits:
          decision.estimatedCredits,
      usableCredits:
          decision.usableCredits,
      reason: decision.reason,
      fallbackResource:
          _findFallback(
            task: task,
            excluded: resource,
          ),
    );
  }

  /// Cerca la prima risorsa autorizzabile seguendo l'ordine
  /// stabilito dalla policy.
  WorkshopExecutionBudgetDecision select({
    required WorkshopTaskContract task,
    WorkshopTaskResource? preferredResource,
  }) {
    final ordered =
        _policy.orderedResources(
      task: task,
      preferredResource:
          preferredResource,
    );

    WorkshopExecutionBudgetDecision? firstFailure;

    for (final resource in ordered) {
      final decision = evaluate(
        task: task,
        resource: resource,
      );

      if (decision.authorized) {
        return decision;
      }

      firstFailure ??= decision;
    }

    return firstFailure ??
        WorkshopExecutionBudgetDecision(
          authorized: false,
          resource:
              preferredResource ??
                  WorkshopTaskResource.local,
          estimatedCredits:
              task.budget.estimatedCredits.toDouble(),
          usableCredits: 0,
          reason:
              'No execution resource is allowed by the current policy.',
        );
  }

  /// Prova a riservare il budget della risorsa selezionata.
  ///
  /// La riserva è interna all'applicazione.
  /// Non rappresenta un consumo reale presso il provider.
  bool tryReserve({
    required WorkshopTaskContract task,
    required WorkshopTaskResource resource,
  }) {
    final decision = evaluate(
      task: task,
      resource: resource,
    );

    if (!decision.authorized) {
      return false;
    }

    return _budgetManager.tryReserve(
      task: task,
      resource: resource,
    );
  }

  /// Seleziona una risorsa e tenta immediatamente
  /// la prenotazione logica del budget.
  ///
  /// Se la prima risorsa non può essere riservata,
  /// prova i fallback nell'ordine stabilito dalla policy.
  WorkshopExecutionBudgetDecision selectAndReserve({
    required WorkshopTaskContract task,
    WorkshopTaskResource? preferredResource,
  }) {
    final ordered =
        _policy.orderedResources(
      task: task,
      preferredResource:
          preferredResource,
    );

    WorkshopExecutionBudgetDecision? lastFailure;

    for (final resource in ordered) {
      final decision = evaluate(
        task: task,
        resource: resource,
      );

      if (!decision.authorized) {
        lastFailure = decision;
        continue;
      }

      final reserved =
          _budgetManager.tryReserve(
        task: task,
        resource: resource,
      );

      if (reserved) {
        return decision;
      }

      lastFailure =
          WorkshopExecutionBudgetDecision(
        authorized: false,
        resource: resource,
        estimatedCredits:
            decision.estimatedCredits,
        usableCredits:
            decision.usableCredits,
        reason:
            'The resource passed budget evaluation but could not be reserved.',
        fallbackResource:
            _findFallback(
              task: task,
              excluded: resource,
            ),
      );
    }

    return lastFailure ??
        WorkshopExecutionBudgetDecision(
          authorized: false,
          resource:
              preferredResource ??
                  WorkshopTaskResource.local,
          estimatedCredits:
              task.budget.estimatedCredits.toDouble(),
          usableCredits: 0,
          reason:
              'No execution resource could be authorized or reserved.',
        );
  }

  /// Rilascia una prenotazione.
  void release({
    required WorkshopTaskResource resource,
    required double credits,
  }) {
    _budgetManager.release(
      resource: resource,
      credits: credits,
    );
  }

  /// Aggiorna il credito disponibile per una risorsa.
  ///
  /// Questo metodo può essere utilizzato successivamente
  /// da un provider/account monitor.
  void updateBudget({
    required WorkshopTaskResource resource,
    required double availableCredits,
    double? minimumReserveCredits,
  }) {
    final minimumReserve =
        minimumReserveCredits ??
            _policy.minimumReserveFor(resource);

    _budgetManager.updateBudget(
      resource: resource,
      availableCredits:
          availableCredits,
      minimumReserveCredits:
          minimumReserve,
    );
  }

  WorkshopTaskResource? _findFallback({
    required WorkshopTaskContract task,
    required WorkshopTaskResource excluded,
  }) {
    final ordered =
        _policy.orderedResources(
      task: task,
    );

    for (final resource in ordered) {
      if (resource == excluded) {
        continue;
      }

      final decision = evaluate(
        task: task,
        resource: resource,
      );

      if (decision.authorized) {
        return resource;
      }
    }

    return null;
  }

  /// Diagnostica completa del controller.
  Map<String, dynamic> diagnostics() {
    return <String, dynamic>{
      'policy': _policy.toJson(),
      'budgetManager':
          _budgetManager.diagnostics(),
    };
  }
}

import 'workshop_task_contract.dart';

/// Stato del budget disponibile per una risorsa.
///
/// Il Cantiere usa questo contratto per decidere se può autorizzare
/// una risorsa prima che il Dispatcher la esegua.
///
/// Il manager NON consuma crediti reali.
final class WorkshopExecutionBudget {
  const WorkshopExecutionBudget({
    required this.availableCredits,
    this.reservedCredits = 0,
    this.minimumReserveCredits = 0,
  });

  final double availableCredits;
  final double reservedCredits;
  final double minimumReserveCredits;

  double get usableCredits {
    final value =
        availableCredits -
        reservedCredits -
        minimumReserveCredits;

    return value < 0 ? 0 : value;
  }

  bool canAfford(double estimatedCredits) {
    if (estimatedCredits <= 0) {
      return true;
    }

    return usableCredits >= estimatedCredits;
  }

  WorkshopExecutionBudget reserve(
    double credits,
  ) {
    if (credits <= 0) {
      return this;
    }

    return WorkshopExecutionBudget(
      availableCredits: availableCredits,
      reservedCredits:
          reservedCredits + credits,
      minimumReserveCredits:
          minimumReserveCredits,
    );
  }

  WorkshopExecutionBudget release(
    double credits,
  ) {
    if (credits <= 0) {
      return this;
    }

    final nextReserved =
        reservedCredits - credits;

    return WorkshopExecutionBudget(
      availableCredits: availableCredits,
      reservedCredits:
          nextReserved < 0
              ? 0
              : nextReserved,
      minimumReserveCredits:
          minimumReserveCredits,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'availableCredits':
          availableCredits,
      'reservedCredits':
          reservedCredits,
      'minimumReserveCredits':
          minimumReserveCredits,
      'usableCredits':
          usableCredits,
    };
  }
}

/// Budget disponibile per una singola risorsa.
///
/// Le risorse locali hanno normalmente costo zero.
///
/// Le risorse cloud/GitHub possono avere un budget separato.
final class WorkshopExecutionResourceBudgets {
  const WorkshopExecutionResourceBudgets({
    this.local =
        const WorkshopExecutionBudget(
      availableCredits:
          double.infinity,
    ),
    this.githubAgent =
        const WorkshopExecutionBudget(
      availableCredits: 0,
    ),
    this.githubActions =
        const WorkshopExecutionBudget(
      availableCredits: 0,
    ),
    this.hybridAi =
        const WorkshopExecutionBudget(
      availableCredits: 0,
    ),
    this.cloud =
        const WorkshopExecutionBudget(
      availableCredits: 0,
    ),
  });

  final WorkshopExecutionBudget local;
  final WorkshopExecutionBudget githubAgent;
  final WorkshopExecutionBudget githubActions;
  final WorkshopExecutionBudget hybridAi;
  final WorkshopExecutionBudget cloud;

  WorkshopExecutionBudget forResource(
    WorkshopTaskResource resource,
  ) {
    switch (resource) {
      case WorkshopTaskResource.local:
        return local;

      case WorkshopTaskResource.githubAgent:
        return githubAgent;

      case WorkshopTaskResource.githubActions:
        return githubActions;

      case WorkshopTaskResource.hybridAi:
        return hybridAi;

      case WorkshopTaskResource.cloud:
        return cloud;
    }
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'local': local.toJson(),
      'githubAgent':
          githubAgent.toJson(),
      'githubActions':
          githubActions.toJson(),
      'hybridAi':
          hybridAi.toJson(),
      'cloud': cloud.toJson(),
    };
  }
}

/// Risultato della verifica del budget.
///
/// Non significa che la task sia stata eseguita:
/// significa solamente che la risorsa è economicamente autorizzabile.
final class WorkshopExecutionBudgetDecision {
  const WorkshopExecutionBudgetDecision({
    required this.authorized,
    required this.resource,
    required this.estimatedCredits,
    required this.usableCredits,
    required this.reason,
    this.fallbackResource,
  });

  final bool authorized;
  final WorkshopTaskResource resource;

  final double estimatedCredits;
  final double usableCredits;

  final String reason;

  final WorkshopTaskResource? fallbackResource;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'authorized': authorized,
      'resource': resource.name,
      'estimatedCredits':
          estimatedCredits,
      'usableCredits':
          usableCredits,
      'reason': reason,
      'fallbackResource':
          fallbackResource?.name,
    };
  }
}

/// Gestore dei budget operativi del Cantiere.
///
/// Principio fondamentale:
///
///     DECIDERE ≠ CONSUMARE
///
/// Questo componente può:
///
/// - verificare un budget;
/// - autorizzare una risorsa;
/// - suggerire un fallback;
/// - riservare logicamente crediti;
/// - rilasciare una riserva.
///
/// NON:
///
/// - chiama OpenAI;
/// - chiama Gemini;
/// - chiama Claude;
/// - chiama Grok;
/// - chiama GitHub Agent;
/// - avvia GitHub Actions;
/// - esegue build;
/// - modifica file.
///
/// Il consumo reale viene effettuato esclusivamente dal relativo executor.
final class WorkshopExecutionBudgetManager {
  WorkshopExecutionBudgetManager({
    WorkshopExecutionResourceBudgets budgets =
        const WorkshopExecutionResourceBudgets(),
  }) : _budgets = budgets;

  WorkshopExecutionResourceBudgets _budgets;

  WorkshopExecutionResourceBudgets get budgets =>
      _budgets;

  /// Verifica se la task può utilizzare la risorsa selezionata.
  WorkshopExecutionBudgetDecision evaluate({
    required WorkshopTaskContract task,
    required WorkshopTaskResource resource,
  }) {
    final estimatedCredits =
        task.budget.estimatedCredits.toDouble();

    final budget =
        _budgets.forResource(resource);

    if (estimatedCredits <= 0) {
      return WorkshopExecutionBudgetDecision(
        authorized: true,
        resource: resource,
        estimatedCredits: 0,
        usableCredits:
            budget.usableCredits,
        reason:
            'The selected resource has no estimated credit cost.',
        fallbackResource:
            _findFallback(
          task: task,
          excluded: resource,
        ),
      );
    }

    if (budget.canAfford(
      estimatedCredits,
    )) {
      return WorkshopExecutionBudgetDecision(
        authorized: true,
        resource: resource,
        estimatedCredits:
            estimatedCredits,
        usableCredits:
            budget.usableCredits,
        reason:
            'Sufficient budget is available for the selected resource.',
        fallbackResource:
            _findFallback(
          task: task,
          excluded: resource,
        ),
      );
    }

    return WorkshopExecutionBudgetDecision(
      authorized: false,
      resource: resource,
      estimatedCredits:
          estimatedCredits,
      usableCredits:
          budget.usableCredits,
      reason:
          'The selected resource does not have enough usable budget.',
      fallbackResource:
          _findAffordableFallback(
        task: task,
        excluded: resource,
      ),
    );
  }

  /// Riserva logicamente il costo stimato di una task.
  ///
  /// Non viene effettuato alcun pagamento reale.
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

    final estimated =
        decision.estimatedCredits;

    if (estimated <= 0) {
      return true;
    }

    final current =
        _budgets.forResource(resource);

    _budgets =
        _replaceBudget(
      resource: resource,
      budget:
          current.reserve(
        estimated,
      ),
    );

    return true;
  }

  /// Rilascia una riserva precedentemente creata.
  void release({
    required WorkshopTaskResource resource,
    required double credits,
  }) {
    if (credits <= 0) {
      return;
    }

    final current =
        _budgets.forResource(resource);

    _budgets =
        _replaceBudget(
      resource: resource,
      budget:
          current.release(
        credits,
      ),
    );
  }

  /// Aggiorna il budget disponibile di una risorsa.
  ///
  /// Utile quando l'app riceve informazioni aggiornate
  /// dal provider remoto.
  ///
  /// IMPORTANTE:
  /// una sincronizzazione del budget disponibile non deve
  /// cancellare le prenotazioni logiche già effettuate.
  void updateBudget({
    required WorkshopTaskResource resource,
    required double availableCredits,
    double minimumReserveCredits = 0,
  }) {
    final current =
        _budgets.forResource(resource);

    final normalizedAvailable =
        availableCredits.isNaN ||
                availableCredits < 0
            ? 0
            : availableCredits;

    final normalizedMinimumReserve =
        minimumReserveCredits.isNaN ||
                minimumReserveCredits < 0
            ? 0
            : minimumReserveCredits;

    _budgets =
        _replaceBudget(
      resource: resource,
      budget:
          WorkshopExecutionBudget(
        availableCredits:
            normalizedAvailable,
        reservedCredits:
            current.reservedCredits,
        minimumReserveCredits:
            normalizedMinimumReserve,
      ),
    );
  }

  /// Cerca il primo fallback dichiarato dalla task
  /// che può essere utilizzato senza superare il budget.
  WorkshopTaskResource?
      _findAffordableFallback({
    required WorkshopTaskContract task,
    required WorkshopTaskResource excluded,
  }) {
    for (final resource
        in task.fallbackResources) {
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

    // Local è sempre il fallback più importante:
    // costo zero e nessun credito cloud.
    if (excluded !=
        WorkshopTaskResource.local) {
      final localDecision =
          evaluate(
        task: task,
        resource:
            WorkshopTaskResource.local,
      );

      if (localDecision.authorized) {
        return WorkshopTaskResource.local;
      }
    }

    return null;
  }

  WorkshopTaskResource? _findFallback({
    required WorkshopTaskContract task,
    required WorkshopTaskResource excluded,
  }) {
    return _findAffordableFallback(
      task: task,
      excluded: excluded,
    );
  }

  WorkshopExecutionResourceBudgets
      _replaceBudget({
    required WorkshopTaskResource resource,
    required WorkshopExecutionBudget budget,
  }) {
    return WorkshopExecutionResourceBudgets(
      local:
          resource ==
                  WorkshopTaskResource.local
              ? budget
              : _budgets.local,
      githubAgent:
          resource ==
                  WorkshopTaskResource.githubAgent
              ? budget
              : _budgets.githubAgent,
      githubActions:
          resource ==
                  WorkshopTaskResource.githubActions
              ? budget
              : _budgets.githubActions,
      hybridAi:
          resource ==
                  WorkshopTaskResource.hybridAi
              ? budget
              : _budgets.hybridAi,
      cloud:
          resource ==
                  WorkshopTaskResource.cloud
              ? budget
              : _budgets.cloud,
    );
  }

  Map<String, dynamic> diagnostics() {
    return <String, dynamic>{
      'budgets':
          _budgets.toJson(),
    };
  }
}

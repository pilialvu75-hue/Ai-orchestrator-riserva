import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';

/// Politica con cui il Cantiere decide quale risorsa privilegiare
/// quando più risorse sono disponibili.
///
/// La policy NON esegue task e NON consuma crediti.
///
/// Il suo compito è soltanto stabilire:
///
/// - priorità delle risorse;
/// - quando preferire LOCAL;
/// - quando consentire HYBRID;
/// - quando usare GitHub;
/// - quando evitare una risorsa costosa.
///
/// Questo permette di cambiare strategia senza modificare
/// Planner, Dispatcher o Executor.
final class WorkshopResourceBudgetPolicy {
  const WorkshopResourceBudgetPolicy({
    this.preferLocal = true,
    this.preferOfflineLocal = true,
    this.preferGithubForRepositoryTasks = true,
    this.preferGithubActionsForBuilds = true,
    this.allowHybridAi = true,
    this.allowCloudFallback = true,
    this.allowGithubFallback = true,
    this.allowLocalFallback = true,
    this.minimumCloudReserveCredits = 1.0,
    this.minimumGithubReserveCredits = 1.0,
    this.minimumHybridReserveCredits = 1.0,
  });

  final bool preferLocal;
  final bool preferOfflineLocal;

  final bool preferGithubForRepositoryTasks;
  final bool preferGithubActionsForBuilds;

  final bool allowHybridAi;
  final bool allowCloudFallback;
  final bool allowGithubFallback;
  final bool allowLocalFallback;

  final double minimumCloudReserveCredits;
  final double minimumGithubReserveCredits;
  final double minimumHybridReserveCredits;

  /// Restituisce le risorse ordinate dalla più appropriata
  /// alla meno appropriata per la task.
  ///
  /// La lista non significa che una risorsa sia disponibile:
  /// la disponibilità reale viene verificata dal Budget Manager
  /// e dal Resource Allocator.
  List<WorkshopTaskResource> orderedResources({
    required WorkshopTaskContract task,
    WorkshopTaskResource? preferredResource,
  }) {
    final result = <WorkshopTaskResource>[];

    void add(WorkshopTaskResource resource) {
      if (result.contains(resource)) {
        return;
      }

      result.add(resource);
    }

    // ----------------------------------------------------------
    // 1. Preferenza esplicita della task.
    // ----------------------------------------------------------
    if (preferredResource != null) {
      add(preferredResource);
    }

    // ----------------------------------------------------------
    // 2. LOCAL.
    //
    // Il principio generale del Cantiere rimane:
    //
    // "non consumare risorse remote se il telefono può
    // fare correttamente il lavoro".
    // ----------------------------------------------------------
    if (preferLocal) {
      add(WorkshopTaskResource.local);
    }

    // ----------------------------------------------------------
    // 3. GitHub Agent.
    //
    // Particolarmente adatto alle task che lavorano sul
    // repository o richiedono creazione/modifica del codice.
    // ----------------------------------------------------------
    if (preferGithubForRepositoryTasks &&
        task.isGithubAgentTask) {
      add(WorkshopTaskResource.githubAgent);
    }

    // ----------------------------------------------------------
    // 4. GitHub Actions.
    //
    // Le build remote devono privilegiare Actions.
    // ----------------------------------------------------------
    if (preferGithubActionsForBuilds &&
        task.kind == WorkshopTaskKind.build) {
      add(WorkshopTaskResource.githubActions);
    }

    // ----------------------------------------------------------
    // 5. HYBRID AI.
    //
    // OpenAI / Gemini / Claude / Grok ecc. vengono considerati
    // supporto, non sostituti automatici del runtime locale.
    // ----------------------------------------------------------
    if (allowHybridAi &&
        task.canUseHybridAi) {
      add(WorkshopTaskResource.hybridAi);
    }

    // ----------------------------------------------------------
    // 6. Cloud puro.
    // ----------------------------------------------------------
    if (allowCloudFallback) {
      add(WorkshopTaskResource.cloud);
    }

    // ----------------------------------------------------------
    // 7. Fallback GitHub generico.
    // ----------------------------------------------------------
    if (allowGithubFallback) {
      add(WorkshopTaskResource.githubAgent);
      add(WorkshopTaskResource.githubActions);
    }

    // ----------------------------------------------------------
    // 8. Fallback LOCAL.
    // ----------------------------------------------------------
    if (allowLocalFallback) {
      add(WorkshopTaskResource.local);
    }

    return List.unmodifiable(result);
  }

  /// Restituisce il limite minimo di riserva da mantenere
  /// per una determinata risorsa.
  double minimumReserveFor(
    WorkshopTaskResource resource,
  ) {
    switch (resource) {
      case WorkshopTaskResource.local:
        return 0;

      case WorkshopTaskResource.githubAgent:
        return minimumGithubReserveCredits;

      case WorkshopTaskResource.githubActions:
        return minimumGithubReserveCredits;

      case WorkshopTaskResource.hybridAi:
        return minimumHybridReserveCredits;

      case WorkshopTaskResource.cloud:
        return minimumCloudReserveCredits;
    }
  }

  /// Indica se la policy considera la risorsa adatta
  /// come fallback automatico.
  bool allowsAutomaticFallback(
    WorkshopTaskResource resource,
  ) {
    switch (resource) {
      case WorkshopTaskResource.local:
        return allowLocalFallback;

      case WorkshopTaskResource.githubAgent:
      case WorkshopTaskResource.githubActions:
        return allowGithubFallback;

      case WorkshopTaskResource.hybridAi:
        return allowHybridAi;

      case WorkshopTaskResource.cloud:
        return allowCloudFallback;
    }
  }

  /// Indica se la policy considera la risorsa "costosa".
  ///
  /// Una risorsa costosa non viene necessariamente vietata:
  /// richiede però una motivazione e un controllo del budget.
  bool isCostly(
    WorkshopTaskResource resource,
  ) {
    switch (resource) {
      case WorkshopTaskResource.local:
        return false;

      case WorkshopTaskResource.githubAgent:
      case WorkshopTaskResource.githubActions:
      case WorkshopTaskResource.hybridAi:
      case WorkshopTaskResource.cloud:
        return true;
    }
  }

  /// Valuta se una risorsa può essere scelta automaticamente
  /// senza una richiesta esplicita dell'utente.
  bool canSelectAutomatically({
    required WorkshopTaskContract task,
    required WorkshopTaskResource resource,
  }) {
    if (resource == WorkshopTaskResource.local) {
      return true;
    }

    if (!isCostly(resource)) {
      return true;
    }

    if (resource == WorkshopTaskResource.githubAgent) {
      return task.isGithubAgentTask;
    }

    if (resource == WorkshopTaskResource.githubActions) {
      return task.kind == WorkshopTaskKind.build;
    }

    if (resource == WorkshopTaskResource.hybridAi) {
      return allowHybridAi &&
          task.canUseHybridAi;
    }

    if (resource == WorkshopTaskResource.cloud) {
      return allowCloudFallback;
    }

    return false;
  }

  /// Costruisce una fotografia della policy per diagnostica,
  /// log e futura UI del Cantiere.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'preferLocal': preferLocal,
      'preferOfflineLocal': preferOfflineLocal,
      'preferGithubForRepositoryTasks':
          preferGithubForRepositoryTasks,
      'preferGithubActionsForBuilds':
          preferGithubActionsForBuilds,
      'allowHybridAi': allowHybridAi,
      'allowCloudFallback': allowCloudFallback,
      'allowGithubFallback': allowGithubFallback,
      'allowLocalFallback': allowLocalFallback,
      'minimumCloudReserveCredits':
          minimumCloudReserveCredits,
      'minimumGithubReserveCredits':
          minimumGithubReserveCredits,
      'minimumHybridReserveCredits':
          minimumHybridReserveCredits,
    };
  }
}

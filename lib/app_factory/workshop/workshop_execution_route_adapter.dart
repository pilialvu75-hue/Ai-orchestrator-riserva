import 'workshop_build_lab.dart';
import 'workshop_execution_mode_router.dart';
import 'workshop_task_contract.dart';
import 'workshop_task_resource_allocator.dart';

/// Adatta la decisione del Execution Mode Router al contratto
/// utilizzato dal Resource Allocator / Execution Guard.
///
/// Flusso:
///
///   ExecutionModeRouter
///          ↓
///   WorkshopExecutionRoute
///          ↓
///   RouteAdapter
///          ↓
///   WorkshopResourceAllocation
///          ↓
///   ExecutionGuard
///          ↓
///   Dispatcher
///
/// Questo componente NON:
///
/// - esegue task;
/// - chiama provider AI;
/// - chiama GitHub;
/// - avvia build;
/// - modifica file;
/// - consuma crediti.
///
/// Traduce solamente una decisione già presa.
final class WorkshopExecutionRouteAdapter {
  const WorkshopExecutionRouteAdapter();

  /// Traduce una route in una ResourceAllocation.
  ///
  /// Restituisce null quando la route non rappresenta una risorsa
  /// eseguibile.
  WorkshopResourceAllocation? adapt({
    required WorkshopTaskContract task,
    required WorkshopExecutionRoute route,
    String? providerId,
  }) {
    final resource = _resourceForRoute(
      task: task,
      route: route,
    );

    if (resource == null) {
      return null;
    }

    final resolvedProviderId =
        providerId ?? _providerForRoute(route);

    final estimatedCredits =
        task.budget.estimatedCredits;

    final requiresNetwork =
        route.networkRequired;

    return WorkshopResourceAllocation(
      taskId: task.id,
      resource: resource,
      providerId: resolvedProviderId,
      reason: route.explanation,
      fallbacks: _fallbacksForRoute(
        task: task,
        route: route,
        selected: resource,
      ),
      estimatedCredits: estimatedCredits,
      estimatedLatencyMs: 0,
      requiresNetwork: requiresNetwork,
    );
  }

  /// Traduce una route in una decisione di allocazione.
  WorkshopResourceAllocation? adaptForTarget({
    required WorkshopTaskContract task,
    required WorkshopBuildTarget target,
    required WorkshopExecutionModeRouter router,
    WorkshopExecutionConstraints constraints =
        const WorkshopExecutionConstraints(),
    String? providerId,
  }) {
    final route = router.route(
      target: target,
      constraints: constraints,
    );

    return adapt(
      task: task,
      route: route,
      providerId: providerId,
    );
  }

  /// Restituisce la risorsa concreta rappresentata dalla route.
  WorkshopTaskResource? _resourceForRoute({
    required WorkshopTaskContract task,
    required WorkshopExecutionRoute route,
  }) {
    // Offline/local sono sempre rappresentati dalla risorsa
    // locale del Cantiere.
    if (route.mode ==
            WorkshopBuildExecutionMode.offlineLocal ||
        route.mode ==
            WorkshopBuildExecutionMode.local) {
      return WorkshopTaskResource.local;
    }

    if (route.mode ==
        WorkshopBuildExecutionMode.remote) {
      // Una route che richiede esplicitamente GitHub deve essere
      // trasformata nella risorsa GitHub appropriata.
      if (route.requiresGithub) {
        return _githubResourceForTask(task);
      }

      // Una route che richiede Cloud AI viene rappresentata
      // come Hybrid quando la task può utilizzare Hybrid AI.
      if (route.requiresCloudAi) {
        if (task.canUseHybridAi) {
          return WorkshopTaskResource.hybridAi;
        }

        return WorkshopTaskResource.cloud;
      }

      // Remote senza indicazione ulteriore:
      //
      // Per le build la risorsa più naturale è GitHub Actions.
      if (task.kind == WorkshopTaskKind.build) {
        return WorkshopTaskResource.githubActions;
      }

      // Per task di codice/repository il GitHub Agent è
      // generalmente più adatto.
      if (task.isGithubAgentTask) {
        return WorkshopTaskResource.githubAgent;
      }

      // Se la task può usare Hybrid AI, la preferiamo
      // alla scelta arbitraria di un provider cloud.
      if (task.canUseHybridAi) {
        return WorkshopTaskResource.hybridAi;
      }

      return WorkshopTaskResource.cloud;
    }

    return null;
  }

  WorkshopTaskResource _githubResourceForTask(
    WorkshopTaskContract task,
  ) {
    // Le build remote devono essere eseguite da Actions.
    if (task.kind == WorkshopTaskKind.build) {
      return WorkshopTaskResource.githubActions;
    }

    // Le task che operano sul repository sono candidate
    // naturali per GitHub Agent.
    if (task.isGithubAgentTask) {
      return WorkshopTaskResource.githubAgent;
    }

    // Per task non direttamente repository-oriented,
    // GitHub Actions è una scelta più conservativa.
    return WorkshopTaskResource.githubActions;
  }

  String? _providerForRoute(
    WorkshopExecutionRoute route,
  ) {
    if (route.requiresGithub) {
      if (route.mode ==
          WorkshopBuildExecutionMode.remote) {
        return 'github';
      }
    }

    if (route.requiresCloudAi) {
      return 'hybrid-ai';
    }

    return null;
  }

  List<WorkshopTaskResource> _fallbacksForRoute({
    required WorkshopTaskContract task,
    required WorkshopExecutionRoute route,
    required WorkshopTaskResource selected,
  }) {
    final result = <WorkshopTaskResource>[];

    void add(
      WorkshopTaskResource resource,
    ) {
      if (resource == selected) {
        return;
      }

      if (result.contains(resource)) {
        return;
      }

      result.add(resource);
    }

    // Prima i fallback esplicitamente dichiarati dalla task.
    for (final resource in task.fallbackResources) {
      add(resource);
    }

    // Poi fallback coerenti con la route.
    if (selected == WorkshopTaskResource.local) {
      if (task.canUseHybridAi) {
        add(WorkshopTaskResource.hybridAi);
      }

      add(WorkshopTaskResource.githubAgent);
      add(WorkshopTaskResource.githubActions);
      add(WorkshopTaskResource.cloud);
    }

    if (selected ==
        WorkshopTaskResource.githubActions) {
      if (task.canUseHybridAi) {
        add(WorkshopTaskResource.hybridAi);
      }

      add(WorkshopTaskResource.cloud);
    }

    if (selected ==
        WorkshopTaskResource.githubAgent) {
      if (task.kind == WorkshopTaskKind.build) {
        add(WorkshopTaskResource.githubActions);
      }

      if (task.canUseHybridAi) {
        add(WorkshopTaskResource.hybridAi);
      }

      add(WorkshopTaskResource.cloud);
    }

    if (selected ==
        WorkshopTaskResource.hybridAi) {
      add(WorkshopTaskResource.local);
      add(WorkshopTaskResource.cloud);
    }

    if (selected ==
        WorkshopTaskResource.cloud) {
      if (task.canUseHybridAi) {
        add(WorkshopTaskResource.hybridAi);
      }

      add(WorkshopTaskResource.local);
    }

    return List.unmodifiable(result);
  }

  /// Produce una descrizione diagnostica della trasformazione.
  Map<String, dynamic> diagnostics({
    required WorkshopTaskContract task,
    required WorkshopExecutionRoute route,
    String? providerId,
  }) {
    final allocation = adapt(
      task: task,
      route: route,
      providerId: providerId,
    );

    return <String, dynamic>{
      'taskId': task.id,
      'route': route.toJson(),
      'allocation':
          allocation?.toJson(),
      'adapted': allocation != null,
    };
  }
}

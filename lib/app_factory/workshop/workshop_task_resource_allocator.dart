import 'workshop_task_contract.dart';

/// Capacità che una risorsa può offrire al Cantiere.
enum WorkshopResourceCapability {
  planning,
  reasoning,
  codeGeneration,
  codeReview,
  repositoryWork,
  localBuild,
  remoteBuild,
  testing,
  staticAnalysis,
  documentation,
  multimodal,
}

/// Stato operativo di una risorsa.
///
/// Il Cantiere non deve confondere "disponibile" con "veloce":
/// una risorsa può essere disponibile ma degradata.
enum WorkshopResourceHealth {
  unavailable,
  degraded,
  available,
  preferred,
}

/// Snapshot delle risorse disponibili in questo momento.
///
/// Questo oggetto NON interroga provider esterni.
/// Rappresenta soltanto lo stato già rilevato da un componente
/// superiore.
final class WorkshopResourceSnapshot {
  const WorkshopResourceSnapshot({
    required this.resource,
    this.providerId,
    this.displayName,
    this.health = WorkshopResourceHealth.available,
    this.available = true,
    this.networkRequired = false,
    this.availableCredits = 0,
    this.estimatedCreditsPerTask = 0,
    this.estimatedLatencyMs = 0,
    this.capabilities = const <WorkshopResourceCapability>[],
    this.metadata = const <String, dynamic>{},
  });

  final WorkshopTaskResource resource;

  /// Identificativo del provider concreto.
  ///
  /// Esempi:
  /// openai
  /// gemini
  /// anthropic
  /// grok
  /// github-copilot
  /// local-llama
  final String? providerId;

  final String? displayName;

  final WorkshopResourceHealth health;
  final bool available;

  /// True se la risorsa non può funzionare senza rete.
  final bool networkRequired;

  /// Credito residuo conosciuto dal Cantiere.
  ///
  /// Non viene interpretato come denaro:
  /// può rappresentare token, richieste, crediti o una
  /// stima normalizzata.
  final double availableCredits;

  /// Stima normalizzata del costo di una task.
  final double estimatedCreditsPerTask;

  /// Stima della latenza.
  final int estimatedLatencyMs;

  final List<WorkshopResourceCapability> capabilities;

  final Map<String, dynamic> metadata;

  bool supports(
    WorkshopResourceCapability capability,
  ) {
    return capabilities.contains(capability);
  }

  bool get isUsable {
    return available &&
        health != WorkshopResourceHealth.unavailable;
  }

  bool canAfford({
    double? estimatedCost,
  }) {
    final cost =
        estimatedCost ?? estimatedCreditsPerTask;

    if (cost <= 0) {
      return true;
    }

    return availableCredits >= cost;
  }

  WorkshopResourceSnapshot copyWith({
    WorkshopResourceHealth? health,
    bool? available,
    double? availableCredits,
    double? estimatedCreditsPerTask,
    int? estimatedLatencyMs,
    List<WorkshopResourceCapability>? capabilities,
    Map<String, dynamic>? metadata,
  }) {
    return WorkshopResourceSnapshot(
      resource: resource,
      providerId: providerId,
      displayName: displayName,
      health: health ?? this.health,
      available: available ?? this.available,
      networkRequired: networkRequired,
      availableCredits:
          availableCredits ?? this.availableCredits,
      estimatedCreditsPerTask:
          estimatedCreditsPerTask ??
              this.estimatedCreditsPerTask,
      estimatedLatencyMs:
          estimatedLatencyMs ??
              this.estimatedLatencyMs,
      capabilities:
          capabilities ?? this.capabilities,
      metadata: metadata ?? this.metadata,
    );
  }
}

/// Decisione prodotta dal Resource Allocator.
///
/// La decisione non avvia la risorsa.
///
/// Indica semplicemente quale risorsa è stata selezionata
/// e perché.
final class WorkshopResourceAllocation {
  const WorkshopResourceAllocation({
    required this.taskId,
    required this.resource,
    this.providerId,
    required this.reason,
    required this.fallbacks,
    this.estimatedCredits = 0,
    this.estimatedLatencyMs = 0,
    this.requiresNetwork = false,
  });

  final String taskId;
  final WorkshopTaskResource resource;
  final String? providerId;
  final String reason;
  final List<WorkshopTaskResource> fallbacks;
  final double estimatedCredits;
  final int estimatedLatencyMs;
  final bool requiresNetwork;

  bool get isLocal =>
      resource == WorkshopTaskResource.local;

  bool get isGithub =>
      resource == WorkshopTaskResource.githubAgent ||
      resource == WorkshopTaskResource.githubActions;

  bool get isHybrid =>
      resource == WorkshopTaskResource.hybridAi;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'taskId': taskId,
      'resource': resource.name,
      'providerId': providerId,
      'reason': reason,
      'fallbacks':
          fallbacks.map((item) => item.name).toList(),
      'estimatedCredits': estimatedCredits,
      'estimatedLatencyMs': estimatedLatencyMs,
      'requiresNetwork': requiresNetwork,
    };
  }
}

/// Risultato di un'allocazione impossibile.
///
/// Il Cantiere deve poter fermarsi senza consumare risorse
/// quando nessuna soluzione sicura è disponibile.
final class WorkshopResourceAllocationFailure {
  const WorkshopResourceAllocationFailure({
    required this.taskId,
    required this.reason,
    this.blockingResources =
        const <WorkshopTaskResource>[],
  });

  final String taskId;
  final String reason;
  final List<WorkshopTaskResource> blockingResources;
}

/// Politica di allocazione delle risorse.
///
/// Le regole sono intenzionalmente conservative:
///
/// 1. non consumare crediti se Local è sufficiente;
/// 2. non usare un provider cloud senza budget;
/// 3. non usare una risorsa degradata se esiste una soluzione sana;
/// 4. rispettare la modalità richiesta dalla task;
/// 5. utilizzare GitHub Agent soltanto quando è realmente adatto;
/// 6. lasciare sempre una possibilità di fallback;
/// 7. non trasformare automaticamente una task in una task Hybrid
///    costosa senza che la policy lo consenta.
final class WorkshopResourceAllocationPolicy {
  const WorkshopResourceAllocationPolicy({
    this.preferLocal = true,
    this.allowDegradedResources = false,
    this.allowHybridFallback = true,
    this.allowGithubAgent = true,
    this.allowGithubActions = true,
    this.minimumCreditReserve = 0.25,
  });

  final bool preferLocal;
  final bool allowDegradedResources;
  final bool allowHybridFallback;
  final bool allowGithubAgent;
  final bool allowGithubActions;

  /// Credito che non deve essere consumato.
  final double minimumCreditReserve;
}

/// Selettore delle risorse del Cantiere.
///
/// Responsabilità:
///
/// - leggere gli snapshot delle risorse;
/// - confrontare capacità e requisiti;
/// - controllare budget e riserve;
/// - scegliere la risorsa più appropriata;
/// - produrre fallback.
///
/// NON:
///
/// - chiama OpenAI;
/// - chiama Gemini;
/// - chiama Claude;
/// - chiama Grok;
/// - chiama GitHub Agent;
/// - avvia GitHub Actions;
/// - esegue la task.
///
/// Questo mantiene separata la decisione dall'esecuzione.
final class WorkshopTaskResourceAllocator {
  const WorkshopTaskResourceAllocator({
    this.policy =
        const WorkshopResourceAllocationPolicy(),
  });

  final WorkshopResourceAllocationPolicy policy;

  /// Tenta di assegnare una risorsa alla task.
  ///
  /// Restituisce null quando nessuna risorsa sicura è disponibile.
  WorkshopResourceAllocation? allocate({
    required WorkshopTaskContract task,
    required List<WorkshopResourceSnapshot> resources,
    bool networkAvailable = true,
  }) {
    final candidates = _buildCandidates(
      task: task,
      resources: resources,
      networkAvailable: networkAvailable,
    );

    if (candidates.isEmpty) {
      return null;
    }

    candidates.sort(
      (a, b) => b.score.compareTo(a.score),
    );

    final selected = candidates.first;

    final fallbacks = candidates
        .skip(1)
        .map((candidate) => candidate.snapshot.resource)
        .toList(growable: false);

    return WorkshopResourceAllocation(
      taskId: task.id,
      resource: selected.snapshot.resource,
      providerId: selected.snapshot.providerId,
      reason: selected.reason,
      fallbacks: fallbacks,
      estimatedCredits:
          selected.snapshot.estimatedCreditsPerTask,
      estimatedLatencyMs:
          selected.snapshot.estimatedLatencyMs,
      requiresNetwork:
          selected.snapshot.networkRequired,
    );
  }

  List<_ScoredResource> _buildCandidates({
    required WorkshopTaskContract task,
    required List<WorkshopResourceSnapshot> resources,
    required bool networkAvailable,
  }) {
    final result = <_ScoredResource>[];

    for (final snapshot in resources) {
      if (!_isAllowed(
        task: task,
        snapshot: snapshot,
      )) {
        continue;
      }

      if (!_isAvailable(
        snapshot: snapshot,
        networkAvailable: networkAvailable,
      )) {
        continue;
      }

      if (!_canAfford(
        task: task,
        snapshot: snapshot,
      )) {
        continue;
      }

      final score = _score(
        task: task,
        snapshot: snapshot,
      );

      result.add(
        _ScoredResource(
          snapshot: snapshot,
          score: score,
          reason: _reason(
            task: task,
            snapshot: snapshot,
          ),
        ),
      );
    }

    return result;
  }

  bool _isAllowed({
    required WorkshopTaskContract task,
    required WorkshopResourceSnapshot snapshot,
  }) {
    if (!snapshot.isUsable) {
      return false;
    }

    if (snapshot.health ==
            WorkshopResourceHealth.degraded &&
        !policy.allowDegradedResources) {
      return false;
    }

    switch (snapshot.resource) {
      case WorkshopTaskResource.githubAgent:
        return policy.allowGithubAgent;

      case WorkshopTaskResource.githubActions:
        return policy.allowGithubActions;

      case WorkshopTaskResource.hybridAi:
        return policy.allowHybridFallback ||
            task.mode == WorkshopTaskMode.hybrid;

      case WorkshopTaskResource.local:
      case WorkshopTaskResource.cloud:
        return true;
    }
  }

  bool _isAvailable({
    required WorkshopResourceSnapshot snapshot,
    required bool networkAvailable,
  }) {
    if (!snapshot.networkRequired) {
      return true;
    }

    return networkAvailable;
  }

  bool _canAfford({
    required WorkshopTaskContract task,
    required WorkshopResourceSnapshot snapshot,
  }) {
    final taskCost = task.budget.estimatedCredits;

    final resourceCost =
        snapshot.estimatedCreditsPerTask;

    final estimatedCost =
        taskCost > 0 ? taskCost : resourceCost;

    if (estimatedCost <= 0) {
      return true;
    }

    final remaining =
        snapshot.availableCredits - estimatedCost;

    return remaining >=
        policy.minimumCreditReserve;
  }

  double _score({
    required WorkshopTaskContract task,
    required WorkshopResourceSnapshot snapshot,
  }) {
    var score = 0.0;

    // Preferenza esplicita della task.
    if (snapshot.resource ==
        task.preferredResource) {
      score += 1000;
    }

    // Fallback esplicito.
    final fallbackIndex =
        task.fallbackResources.indexOf(
      snapshot.resource,
    );

    if (fallbackIndex >= 0) {
      score += 500 - fallbackIndex * 25;
    }

    // Local evita consumo cloud quando possibile.
    if (policy.preferLocal &&
        snapshot.resource ==
            WorkshopTaskResource.local) {
      score += 300;
    }

    // Risorsa Hybrid solo quando realmente utile.
    if (snapshot.resource ==
            WorkshopTaskResource.hybridAi &&
        task.canUseHybridAi) {
      score += 180;
    }

    // GitHub Agent è potente ma deve essere usato
    // quando la task richiede lavoro autonomo sul repository.
    if (snapshot.resource ==
            WorkshopTaskResource.githubAgent &&
        task.isGithubAgentTask) {
      score += 220;
    }

    if (snapshot.resource ==
            WorkshopTaskResource.githubActions &&
        task.kind == WorkshopTaskKind.build) {
      score += 220;
    }

    // Capacità compatibili.
    score += _capabilityScore(
      task: task,
      snapshot: snapshot,
    );

    // Risorse preferred hanno priorità rispetto a quelle degradate.
    switch (snapshot.health) {
      case WorkshopResourceHealth.preferred:
        score += 100;

      case WorkshopResourceHealth.available:
        score += 50;

      case WorkshopResourceHealth.degraded:
        score -= 100;

      case WorkshopResourceHealth.unavailable:
        score -= 10000;
    }

    // Penalizza consumo cloud.
    if (snapshot.resource !=
        WorkshopTaskResource.local) {
      score -=
          snapshot.estimatedCreditsPerTask * 10;
    }

    // Penalizza latenza elevata, ma senza farla
    // diventare più importante della correttezza.
    if (snapshot.estimatedLatencyMs > 0) {
      score -=
          snapshot.estimatedLatencyMs / 10000;
    }

    return score;
  }

  double _capabilityScore({
    required WorkshopTaskContract task,
    required WorkshopResourceSnapshot snapshot,
  }) {
    var score = 0.0;

    switch (task.kind) {
      case WorkshopTaskKind.analysis:
      case WorkshopTaskKind.planning:
        if (snapshot.supports(
          WorkshopResourceCapability.planning,
        )) {
          score += 50;
        }

        if (snapshot.supports(
          WorkshopResourceCapability.reasoning,
        )) {
          score += 40;
        }

      case WorkshopTaskKind.codeGeneration:
      case WorkshopTaskKind.codeModification:
        if (snapshot.supports(
          WorkshopResourceCapability.codeGeneration,
        )) {
          score += 60;
        }

        if (snapshot.supports(
          WorkshopResourceCapability.repositoryWork,
        )) {
          score += 40;
        }

      case WorkshopTaskKind.test:
      case WorkshopTaskKind.lint:
        if (snapshot.supports(
          WorkshopResourceCapability.testing,
        )) {
          score += 60;
        }

        if (snapshot.supports(
          WorkshopResourceCapability.staticAnalysis,
        )) {
          score += 40;
        }

      case WorkshopTaskKind.build:
        if (snapshot.supports(
          WorkshopResourceCapability.localBuild,
        )) {
          score += 60;
        }

        if (snapshot.supports(
          WorkshopResourceCapability.remoteBuild,
        )) {
          score += 60;
        }

      case WorkshopTaskKind.debugging:
        if (snapshot.supports(
          WorkshopResourceCapability.reasoning,
        )) {
          score += 50;
        }

        if (snapshot.supports(
          WorkshopResourceCapability.codeReview,
        )) {
          score += 30;
        }

      case WorkshopTaskKind.documentation:
        if (snapshot.supports(
          WorkshopResourceCapability.documentation,
        )) {
          score += 50;
        }

      case WorkshopTaskKind.review:
        if (snapshot.supports(
          WorkshopResourceCapability.codeReview,
        )) {
          score += 60;
        }

        if (snapshot.supports(
          WorkshopResourceCapability.staticAnalysis,
        )) {
          score += 30;
        }

      case WorkshopTaskKind.integration:
        if (snapshot.supports(
          WorkshopResourceCapability.repositoryWork,
        )) {
          score += 50;
        }
    }

    return score;
  }

  String _reason({
    required WorkshopTaskContract task,
    required WorkshopResourceSnapshot snapshot,
  }) {
    if (snapshot.resource ==
            WorkshopTaskResource.local &&
        policy.preferLocal) {
      return 'Local resource selected to avoid unnecessary '
          'cloud/provider credit consumption.';
    }

    if (snapshot.resource ==
            WorkshopTaskResource.githubAgent &&
        task.isGithubAgentTask) {
      return 'GitHub Agent selected because the task is '
          'explicitly suitable for autonomous repository work.';
    }

    if (snapshot.resource ==
            WorkshopTaskResource.githubActions &&
        task.kind == WorkshopTaskKind.build) {
      return 'GitHub Actions selected because the required '
          'build capability is remote.';
    }

    if (snapshot.resource ==
        WorkshopTaskResource.hybridAi) {
      return 'Hybrid AI selected because the task permits '
          'multi-provider collaboration.';
    }

    if (snapshot.providerId != null) {
      return 'Provider ${snapshot.providerId} selected '
          'according to task capability, availability and budget.';
    }

    return 'Resource selected according to task capability, '
        'availability, health and budget.';
  }
}

final class _ScoredResource {
  const _ScoredResource({
    required this.snapshot,
    required this.score,
    required this.reason,
  });

  final WorkshopResourceSnapshot snapshot;
  final double score;
  final String reason;
}

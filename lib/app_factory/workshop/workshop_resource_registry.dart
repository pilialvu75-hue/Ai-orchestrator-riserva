import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_resource_allocator.dart';

/// Registro centralizzato delle risorse disponibili al Cantiere.
///
/// Il Registry rappresenta lo stato corrente delle risorse, ma non
/// esegue nessuna operazione.
///
/// Responsabilità:
///
/// - registrare le risorse disponibili;
/// - aggiornare il loro stato;
/// - aggiornare crediti e latenza stimata;
/// - esporre snapshot coerenti al Resource Allocator;
/// - distinguere risorse locali, cloud e GitHub;
/// - conservare metadati utili per decisioni future.
///
/// NON:
///
/// - esegue task;
/// - chiama direttamente provider AI;
/// - avvia GitHub Actions;
/// - avvia GitHub Agent;
/// - modifica repository;
/// - effettua build.
///
/// Questo mantiene il Registry come componente infrastrutturale
/// semplice e prevedibile.
final class WorkshopResourceRegistry {
  WorkshopResourceRegistry({
    Iterable<WorkshopResourceSnapshot> initialResources =
        const <WorkshopResourceSnapshot>[],
  }) {
    registerAll(initialResources);
  }

  final Map<String, WorkshopResourceSnapshot> _resources =
      <String, WorkshopResourceSnapshot>{};

  /// Numero di risorse registrate.
  int get length => _resources.length;

  /// True quando non esiste nessuna risorsa registrata.
  bool get isEmpty => _resources.isEmpty;

  /// True quando esiste almeno una risorsa.
  bool get isNotEmpty => _resources.isNotEmpty;

  /// Tutte le risorse registrate.
  List<WorkshopResourceSnapshot> get all {
    return List.unmodifiable(
      _resources.values,
    );
  }

  /// Risorse attualmente utilizzabili.
  List<WorkshopResourceSnapshot> get usable {
    return List.unmodifiable(
      _resources.values.where(
        (resource) => resource.isUsable,
      ),
    );
  }

  /// Risorse che richiedono rete.
  List<WorkshopResourceSnapshot> get networkResources {
    return List.unmodifiable(
      _resources.values.where(
        (resource) => resource.networkRequired,
      ),
    );
  }

  /// Risorse locali.
  List<WorkshopResourceSnapshot> get localResources {
    return List.unmodifiable(
      _resources.values.where(
        (resource) =>
            resource.resource ==
            WorkshopTaskResource.local,
      ),
    );
  }

  /// Risorse cloud / Hybrid.
  List<WorkshopResourceSnapshot> get cloudResources {
    return List.unmodifiable(
      _resources.values.where(
        (resource) =>
            resource.resource ==
                WorkshopTaskResource.cloud ||
            resource.resource ==
                WorkshopTaskResource.hybridAi,
      ),
    );
  }

  /// Risorse GitHub.
  List<WorkshopResourceSnapshot> get githubResources {
    return List.unmodifiable(
      _resources.values.where(
        (resource) =>
            resource.resource ==
                WorkshopTaskResource.githubAgent ||
            resource.resource ==
                WorkshopTaskResource.githubActions,
      ),
    );
  }

  /// Registra una nuova risorsa.
  ///
  /// Se una risorsa con lo stesso identificatore esiste già,
  /// viene sostituita dallo snapshot più recente.
  void register(
    WorkshopResourceSnapshot snapshot,
  ) {
    _resources[_key(snapshot)] = snapshot;
  }

  /// Registra più risorse.
  void registerAll(
    Iterable<WorkshopResourceSnapshot> snapshots,
  ) {
    for (final snapshot in snapshots) {
      register(snapshot);
    }
  }

  /// Restituisce una risorsa specifica.
  WorkshopResourceSnapshot? find({
    required WorkshopTaskResource resource,
    String? providerId,
  }) {
    final normalizedProviderId =
        providerId?.trim();

    if (normalizedProviderId != null &&
        normalizedProviderId.isNotEmpty) {
      return _resources[
          _keyFromValues(
        resource,
        normalizedProviderId,
      )];
    }

    for (final snapshot in _resources.values) {
      if (snapshot.resource == resource) {
        return snapshot;
      }
    }

    return null;
  }

  /// Restituisce tutte le istanze di una categoria.
  List<WorkshopResourceSnapshot> findAll(
    WorkshopTaskResource resource,
  ) {
    return List.unmodifiable(
      _resources.values.where(
        (snapshot) =>
            snapshot.resource == resource,
      ),
    );
  }

  /// Verifica se una risorsa è registrata.
  bool contains({
    required WorkshopTaskResource resource,
    String? providerId,
  }) {
    return find(
          resource: resource,
          providerId: providerId,
        ) !=
        null;
  }

  /// Aggiorna lo stato di salute di una risorsa.
  bool updateHealth({
    required WorkshopTaskResource resource,
    String? providerId,
    required WorkshopResourceHealth health,
  }) {
    final current = find(
      resource: resource,
      providerId: providerId,
    );

    if (current == null) {
      return false;
    }

    register(
      current.copyWith(
        health: health,
      ),
    );

    return true;
  }

  /// Aggiorna la disponibilità di una risorsa.
  bool updateAvailability({
    required WorkshopTaskResource resource,
    String? providerId,
    required bool available,
  }) {
    final current = find(
      resource: resource,
      providerId: providerId,
    );

    if (current == null) {
      return false;
    }

    register(
      current.copyWith(
        available: available,
        health: available
            ? current.health ==
                    WorkshopResourceHealth.unavailable
                ? WorkshopResourceHealth.available
                : current.health
            : WorkshopResourceHealth.unavailable,
      ),
    );

    return true;
  }

  /// Aggiorna il credito residuo.
  bool updateCredits({
    required WorkshopTaskResource resource,
    String? providerId,
    required double availableCredits,
  }) {
    final current = find(
      resource: resource,
      providerId: providerId,
    );

    if (current == null) {
      return false;
    }

    register(
      current.copyWith(
        availableCredits:
            availableCredits < 0
                ? 0
                : availableCredits,
      ),
    );

    return true;
  }

  /// Aggiorna la stima del costo della task.
  bool updateEstimatedCost({
    required WorkshopTaskResource resource,
    String? providerId,
    required double estimatedCreditsPerTask,
  }) {
    final current = find(
      resource: resource,
      providerId: providerId,
    );

    if (current == null) {
      return false;
    }

    register(
      current.copyWith(
        estimatedCreditsPerTask:
            estimatedCreditsPerTask < 0
                ? 0
                : estimatedCreditsPerTask,
      ),
    );

    return true;
  }

  /// Aggiorna la latenza stimata.
  bool updateLatency({
    required WorkshopTaskResource resource,
    String? providerId,
    required int estimatedLatencyMs,
  }) {
    final current = find(
      resource: resource,
      providerId: providerId,
    );

    if (current == null) {
      return false;
    }

    register(
      current.copyWith(
        estimatedLatencyMs:
            estimatedLatencyMs < 0
                ? 0
                : estimatedLatencyMs,
      ),
    );

    return true;
  }

  /// Aggiorna metadati senza modificare il resto dello snapshot.
  bool updateMetadata({
    required WorkshopTaskResource resource,
    String? providerId,
    required Map<String, dynamic> metadata,
  }) {
    final current = find(
      resource: resource,
      providerId: providerId,
    );

    if (current == null) {
      return false;
    }

    register(
      current.copyWith(
        metadata: Map.unmodifiable(
          metadata,
        ),
      ),
    );

    return true;
  }

  /// Rimuove una risorsa dal registro.
  bool remove({
    required WorkshopTaskResource resource,
    String? providerId,
  }) {
    final current = find(
      resource: resource,
      providerId: providerId,
    );

    if (current == null) {
      return false;
    }

    return _resources
        .remove(_key(current)) !=
        null;
  }

  /// Rimuove tutte le risorse di una categoria.
  int removeAll(
    WorkshopTaskResource resource,
  ) {
    final keys = _resources.entries
        .where(
          (entry) =>
              entry.value.resource ==
              resource,
        )
        .map(
          (entry) => entry.key,
        )
        .toList(growable: false);

    for (final key in keys) {
      _resources.remove(key);
    }

    return keys.length;
  }

  /// Svuota completamente il registro.
  void clear() {
    _resources.clear();
  }

  /// Verifica rapidamente se esiste una risorsa locale utilizzabile.
  bool get hasUsableLocal {
    return localResources.any(
      (resource) => resource.isUsable,
    );
  }

  /// Verifica rapidamente se esiste GitHub Agent utilizzabile.
  bool get hasUsableGithubAgent {
    return githubResources.any(
      (resource) =>
          resource.resource ==
              WorkshopTaskResource.githubAgent &&
          resource.isUsable,
    );
  }

  /// Verifica rapidamente se esiste GitHub Actions utilizzabile.
  bool get hasUsableGithubActions {
    return githubResources.any(
      (resource) =>
          resource.resource ==
              WorkshopTaskResource.githubActions &&
          resource.isUsable,
    );
  }

  /// Verifica se esiste almeno una risorsa cloud utilizzabile.
  bool get hasUsableCloud {
    return cloudResources.any(
      (resource) => resource.isUsable,
    );
  }

  /// Verifica se esiste una risorsa con una determinata capacità.
  bool hasCapability(
    WorkshopResourceCapability capability,
  ) {
    return usable.any(
      (resource) =>
          resource.supports(capability),
    );
  }

  /// Restituisce le risorse che possiedono una determinata capacità.
  List<WorkshopResourceSnapshot> withCapability(
    WorkshopResourceCapability capability,
  ) {
    return List.unmodifiable(
      usable.where(
        (resource) =>
            resource.supports(capability),
      ),
    );
  }

  /// Produce lo snapshot che verrà passato al Resource Allocator.
  ///
  /// Il Registry non prende decisioni.
  /// L'Allocator utilizzerà questa lista per scegliere la risorsa.
  List<WorkshopResourceSnapshot> snapshot() {
    return List.unmodifiable(
      _resources.values,
    );
  }

  /// Esporta lo stato del Registry.
  ///
  /// Utile per:
  ///
  /// - checkpoint del Workshop;
  /// - diagnostica;
  /// - background service;
  /// - Project Hub;
  /// - audit;
  /// - ripristino dopo kill/OOM.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'resources': _resources.values
          .map(
            (resource) => <String, dynamic>{
              'resource':
                  resource.resource.name,
              'providerId':
                  resource.providerId,
              'displayName':
                  resource.displayName,
              'health':
                  resource.health.name,
              'available':
                  resource.available,
              'networkRequired':
                  resource.networkRequired,
              'availableCredits':
                  resource.availableCredits,
              'estimatedCreditsPerTask':
                  resource.estimatedCreditsPerTask,
              'estimatedLatencyMs':
                  resource.estimatedLatencyMs,
              'capabilities':
                  resource.capabilities
                      .map(
                        (capability) =>
                            capability.name,
                      )
                      .toList(
                        growable: false,
                      ),
              'metadata':
                  resource.metadata,
            },
          )
          .toList(growable: false),
    };
  }

  String _key(
    WorkshopResourceSnapshot snapshot,
  ) {
    return _keyFromValues(
      snapshot.resource,
      snapshot.providerId,
    );
  }

  String _keyFromValues(
    WorkshopTaskResource resource,
    String? providerId,
  ) {
    final provider =
        providerId?.trim();

    if (provider == null ||
        provider.isEmpty) {
      return resource.name;
    }

    return '${resource.name}:$provider';
  }
}

/// Costanti per identificare provider conosciuti.
///
/// Il Registry non richiede che tutti questi provider siano
/// presenti: sono semplicemente identificatori standardizzati.
///
/// In questo modo possiamo aggiungere o rimuovere provider
/// senza modificare la logica del Resource Allocator.
abstract final class WorkshopProviderIds {
  static const String localLlm = 'local-llm';

  static const String openAi = 'openai';
  static const String gemini = 'gemini';
  static const String anthropic = 'anthropic';
  static const String grok = 'grok';

  static const String githubAgent = 'github-agent';
  static const String githubActions = 'github-actions';

  static const String localFlutter =
      'local-flutter-toolchain';

  static const String localAndroid =
      'local-android-toolchain';

  static const String localLinux =
      'local-linux-toolchain';

  static const String localWindows =
      'local-windows-toolchain';

  static const String localMacos =
      'local-macos-toolchain';

  static const String localIos =
      'local-ios-toolchain';

  static const String cadFusion =
      'fusion-360';

  static const String cadFreeCad =
      'freecad';

  static const String printer3d =
      '3d-printer';
}

/// Factory di snapshot standard per il modello locale.
///
/// Serve a evitare che ogni componente costruisca manualmente
/// gli stessi metadati.
abstract final class WorkshopResourceDefaults {
  static WorkshopResourceSnapshot localLlm({
    double availableCredits = 0,
    double estimatedCreditsPerTask = 0,
    int estimatedLatencyMs = 0,
    WorkshopResourceHealth health =
        WorkshopResourceHealth.available,
    bool available = true,
    Map<String, dynamic> metadata =
        const <String, dynamic>{},
  }) {
    return WorkshopResourceSnapshot(
      resource: WorkshopTaskResource.local,
      providerId:
          WorkshopProviderIds.localLlm,
      displayName: 'Local LLM',
      health: health,
      available: available,
      networkRequired: false,
      availableCredits: availableCredits,
      estimatedCreditsPerTask:
          estimatedCreditsPerTask,
      estimatedLatencyMs:
          estimatedLatencyMs,
      capabilities: const <WorkshopResourceCapability>[
        WorkshopResourceCapability.planning,
        WorkshopResourceCapability.reasoning,
        WorkshopResourceCapability.codeGeneration,
        WorkshopResourceCapability.codeReview,
        WorkshopResourceCapability.testing,
        WorkshopResourceCapability.staticAnalysis,
        WorkshopResourceCapability.documentation,
      ],
      metadata: Map.unmodifiable(metadata),
    );
  }

  static WorkshopResourceSnapshot openAi({
    required double availableCredits,
    double estimatedCreditsPerTask = 1,
    int estimatedLatencyMs = 0,
    WorkshopResourceHealth health =
        WorkshopResourceHealth.available,
    bool available = true,
    Map<String, dynamic> metadata =
        const <String, dynamic>{},
  }) {
    return WorkshopResourceSnapshot(
      resource: WorkshopTaskResource.cloud,
      providerId:
          WorkshopProviderIds.openAi,
      displayName: 'OpenAI',
      health: health,
      available: available,
      networkRequired: true,
      availableCredits: availableCredits,
      estimatedCreditsPerTask:
          estimatedCreditsPerTask,
      estimatedLatencyMs:
          estimatedLatencyMs,
      capabilities: const <WorkshopResourceCapability>[
        WorkshopResourceCapability.planning,
        WorkshopResourceCapability.reasoning,
        WorkshopResourceCapability.codeGeneration,
        WorkshopResourceCapability.codeReview,
        WorkshopResourceCapability.repositoryWork,
        WorkshopResourceCapability.documentation,
        WorkshopResourceCapability.multimodal,
      ],
      metadata: Map.unmodifiable(metadata),
    );
  }

  static WorkshopResourceSnapshot gemini({
    required double availableCredits,
    double estimatedCreditsPerTask = 1,
    int estimatedLatencyMs = 0,
    WorkshopResourceHealth health =
        WorkshopResourceHealth.available,
    bool available = true,
    Map<String, dynamic> metadata =
        const <String, dynamic>{},
  }) {
    return WorkshopResourceSnapshot(
      resource: WorkshopTaskResource.cloud,
      providerId:
          WorkshopProviderIds.gemini,
      displayName: 'Gemini',
      health: health,
      available: available,
      networkRequired: true,
      availableCredits: availableCredits,
      estimatedCreditsPerTask:
          estimatedCreditsPerTask,
      estimatedLatencyMs:
          estimatedLatencyMs,
      capabilities: const <WorkshopResourceCapability>[
        WorkshopResourceCapability.planning,
        WorkshopResourceCapability.reasoning,
        WorkshopResourceCapability.codeGeneration,
        WorkshopResourceCapability.codeReview,
        WorkshopResourceCapability.documentation,
        WorkshopResourceCapability.multimodal,
      ],
      metadata: Map.unmodifiable(metadata),
    );
  }

  static WorkshopResourceSnapshot anthropic({
    required double availableCredits,
    double estimatedCreditsPerTask = 1,
    int estimatedLatencyMs = 0,
    WorkshopResourceHealth health =
        WorkshopResourceHealth.available,
    bool available = true,
    Map<String, dynamic> metadata =
        const <String, dynamic>{},
  }) {
    return WorkshopResourceSnapshot(
      resource: WorkshopTaskResource.cloud,
      providerId:
          WorkshopProviderIds.anthropic,
      displayName: 'Claude',
      health: health,
      available: available,
      networkRequired: true,
      availableCredits: availableCredits,
      estimatedCreditsPerTask:
          estimatedCreditsPerTask,
      estimatedLatencyMs:
          estimatedLatencyMs,
      capabilities: const <WorkshopResourceCapability>[
        WorkshopResourceCapability.planning,
        WorkshopResourceCapability.reasoning,
        WorkshopResourceCapability.codeGeneration,
        WorkshopResourceCapability.codeReview,
        WorkshopResourceCapability.repositoryWork,
        WorkshopResourceCapability.documentation,
      ],
      metadata: Map.unmodifiable(metadata),
    );
  }

  static WorkshopResourceSnapshot grok({
    required double availableCredits,
    double estimatedCreditsPerTask = 1,
    int estimatedLatencyMs = 0,
    WorkshopResourceHealth health =
        WorkshopResourceHealth.available,
    bool available = true,
    Map<String, dynamic> metadata =
        const <String, dynamic>{},
  }) {
    return WorkshopResourceSnapshot(
      resource: WorkshopTaskResource.cloud,
      providerId:
          WorkshopProviderIds.grok,
      displayName: 'Grok',
      health: health,
      available: available,
      networkRequired: true,
      availableCredits: availableCredits,
      estimatedCreditsPerTask:
          estimatedCreditsPerTask,
      estimatedLatencyMs:
          estimatedLatencyMs,
      capabilities: const <WorkshopResourceCapability>[
        WorkshopResourceCapability.planning,
        WorkshopResourceCapability.reasoning,
        WorkshopResourceCapability.codeGeneration,
        WorkshopResourceCapability.codeReview,
        WorkshopResourceCapability.documentation,
      ],
      metadata: Map.unmodifiable(metadata),
    );
  }

  static WorkshopResourceSnapshot githubAgent({
    required double availableCredits,
    double estimatedCreditsPerTask = 1,
    int estimatedLatencyMs = 0,
    WorkshopResourceHealth health =
        WorkshopResourceHealth.available,
    bool available = true,
    Map<String, dynamic> metadata =
        const <String, dynamic>{},
  }) {
    return WorkshopResourceSnapshot(
      resource:
          WorkshopTaskResource.githubAgent,
      providerId:
          WorkshopProviderIds.githubAgent,
      displayName: 'GitHub Agent',
      health: health,
      available: available,
      networkRequired: true,
      availableCredits: availableCredits,
      estimatedCreditsPerTask:
          estimatedCreditsPerTask,
      estimatedLatencyMs:
          estimatedLatencyMs,
      capabilities: const <WorkshopResourceCapability>[
        WorkshopResourceCapability.codeGeneration,
        WorkshopResourceCapability.repositoryWork,
        WorkshopResourceCapability.codeReview,
        WorkshopResourceCapability.testing,
        WorkshopResourceCapability.staticAnalysis,
      ],
      metadata: Map.unmodifiable(metadata),
    );
  }

  static WorkshopResourceSnapshot githubActions({
    required double availableCredits,
    double estimatedCreditsPerTask = 0,
    int estimatedLatencyMs = 0,
    WorkshopResourceHealth health =
        WorkshopResourceHealth.available,
    bool available = true,
    Map<String, dynamic> metadata =
        const <String, dynamic>{},
  }) {
    return WorkshopResourceSnapshot(
      resource:
          WorkshopTaskResource.githubActions,
      providerId:
          WorkshopProviderIds.githubActions,
      displayName: 'GitHub Actions',
      health: health,
      available: available,
      networkRequired: true,
      availableCredits: availableCredits,
      estimatedCreditsPerTask:
          estimatedCreditsPerTask,
      estimatedLatencyMs:
          estimatedLatencyMs,
      capabilities: const <WorkshopResourceCapability>[
        WorkshopResourceCapability.remoteBuild,
        WorkshopResourceCapability.testing,
        WorkshopResourceCapability.staticAnalysis,
        WorkshopResourceCapability.repositoryWork,
      ],
      metadata: Map.unmodifiable(metadata),
    );
  }
}

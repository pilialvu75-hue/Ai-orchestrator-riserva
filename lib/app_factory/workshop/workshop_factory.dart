import 'package:get_it/get_it.dart';

import '../workspace/local_git_workspace_gateway.dart';

import 'workshop_dashboard_controller.dart';
import 'workshop_engine.dart';
import 'workshop_inference_gateway.dart';
import 'workshop_inference_provider_adapter.dart';
import 'workshop_project_executor.dart';

import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';

/// Composition root del Cantiere.
///
/// Costruisce le dipendenze principali senza inserire logica di
/// esecuzione nella UI.
///
/// Pipeline:
///
///   DashboardController
///          ↓
///   WorkshopEngine
///          ↓
///   WorkshopInferenceGateway
///          ↓
///   WorkshopInferenceProviderAdapter
///          ↓
///   InferenceService
///          ↓
///   Local / Cloud runtime
///
/// e parallelamente:
///
///   WorkshopEngine
///          ↓
///   WorkshopProjectExecutor
///          ↓
///   LocalGitWorkspaceGateway
///          ↓
///   WorkspaceSession
///          ↓
///   VirtualWorkspace
///
/// Il Cantiere NON dipende dalla Chat Assistente.
///
/// Riutilizza esclusivamente l'infrastruttura di inferenza già presente
/// nell'applicazione attraverso un contratto stabile.
///
final class WorkshopFactory {
  const WorkshopFactory._();

  /// Crea il gateway locale del Workspace.
  ///
  /// [workspaceRootPath] deve indicare la directory reale del progetto
  /// su cui il Cantiere dovrà lavorare.
  ///
  /// Il gateway non esegue automaticamente operazioni Git remote:
  /// branch, commit, push e Pull Request rimangono responsabilità
  /// di un backend Git successivo.
  static LocalGitWorkspaceGateway createWorkspaceGateway({
    required String workspaceRootPath,
    bool includeHiddenFiles = false,
    int maxFileSizeBytes = 10 * 1024 * 1024,
  }) {
    final normalizedPath = workspaceRootPath.trim();

    if (normalizedPath.isEmpty) {
      throw ArgumentError.value(
        workspaceRootPath,
        'workspaceRootPath',
        'Workspace root path cannot be empty.',
      );
    }

    if (maxFileSizeBytes <= 0) {
      throw ArgumentError.value(
        maxFileSizeBytes,
        'maxFileSizeBytes',
        'Maximum file size must be greater than zero.',
      );
    }

    return LocalGitWorkspaceGateway(
      rootPath: normalizedPath,
      includeHiddenFiles: includeHiddenFiles,
      maxFileSizeBytes: maxFileSizeBytes,
    );
  }

  /// Crea un ProjectExecutor collegato al Workspace locale.
  ///
  /// Questo è il punto in cui il ProjectPlan del Cantiere viene
  /// collegato al WorkspaceSession reale.
  static WorkshopProjectExecutor createProjectExecutor({
    required String workspaceRootPath,
    bool includeHiddenFiles = false,
    int maxFileSizeBytes = 10 * 1024 * 1024,
  }) {
    final gateway = createWorkspaceGateway(
      workspaceRootPath: workspaceRootPath,
      includeHiddenFiles: includeHiddenFiles,
      maxFileSizeBytes: maxFileSizeBytes,
    );

    return WorkshopProjectExecutor(
      gateway: gateway,
    );
  }

  /// Risolve l'InferenceService già registrato nell'application container.
  ///
  /// Il Cantiere non crea un secondo runtime AI.
  ///
  /// Utilizza esclusivamente il contratto InferenceService già esistente,
  /// che mantiene la propria gestione di:
  ///
  /// - runtime locale;
  /// - runtime cloud;
  /// - modello selezionato;
  /// - sessione;
  /// - fallback;
  /// - provider.
  ///
  /// Se l'applicazione non ha ancora inizializzato il container DI,
  /// l'errore viene lasciato propagare invece di creare un falso provider.
  static InferenceService resolveInferenceService({
    InferenceService? inferenceService,
  }) {
    if (inferenceService != null) {
      return inferenceService;
    }

    final locator = GetIt.instance;

    if (!locator.isRegistered<InferenceService>()) {
      throw StateError(
        'InferenceService is not registered. '
        'Initialize application dependencies before creating the Workshop.',
      );
    }

    return locator<InferenceService>();
  }

  /// Crea il provider indipendente del Cantiere sopra InferenceService.
  ///
  /// Questo adapter mantiene separati:
  ///
  ///   Assistente
  ///       ↓
  ///   InferenceService
  ///
  /// e
  ///
  ///   Cantiere
  ///       ↓
  ///   WorkshopInferenceGateway
  ///       ↓
  ///   WorkshopInferenceProviderAdapter
  ///       ↓
  ///   InferenceService
  ///
  /// Condividono quindi infrastruttura, ma non controller,
  /// conversazione o memoria dell'Assistente.
  static WorkshopInferenceProviderAdapter
      createInferenceProviderAdapter({
    InferenceService? inferenceService,
  }) {
    final resolvedInferenceService =
        resolveInferenceService(
      inferenceService: inferenceService,
    );

    return WorkshopInferenceProviderAdapter(
      inferenceService: resolvedInferenceService,
    );
  }

  /// Crea il gateway di inferenza del Cantiere.
  ///
  /// [inferenceGateway] può essere fornito esplicitamente per test,
  /// sostituzioni o configurazioni future.
  ///
  /// In assenza di un gateway esplicito viene utilizzato il runtime
  /// dell'applicazione attraverso il Workshop adapter.
  static WorkshopInferenceGateway
      createInferenceGateway({
    InferenceService? inferenceService,
    WorkshopInferenceGateway? inferenceGateway,
  }) {
    if (inferenceGateway != null) {
      return inferenceGateway;
    }

    final provider =
        createInferenceProviderAdapter(
      inferenceService: inferenceService,
    );

    return WorkshopInferenceGateway(
      provider: provider,
    );
  }

  /// Crea un WorkshopEngine già collegato al ProjectExecutor e
  /// al cervello AI indipendente del Cantiere.
  ///
  /// Se [projectExecutor] viene fornito esplicitamente, viene usato
  /// direttamente.
  ///
  /// Se [projectExecutor] non viene fornito, il factory lo costruisce
  /// automaticamente quando è disponibile [workspaceRootPath].
  ///
  /// Se [inferenceGateway] non viene fornito, il factory collega
  /// automaticamente il Workshop al RuntimeInferenceProvider
  /// dell'applicazione attraverso WorkshopInferenceProviderAdapter.
  static WorkshopEngine createEngine({
    String? workspaceRootPath,
    WorkshopProjectExecutor? projectExecutor,
    InferenceService? inferenceService,
    WorkshopInferenceGateway? inferenceGateway,
    bool includeHiddenFiles = false,
    int maxFileSizeBytes = 10 * 1024 * 1024,
  }) {
    final resolvedExecutor =
        projectExecutor ??
        _createOptionalProjectExecutor(
          workspaceRootPath: workspaceRootPath,
          includeHiddenFiles: includeHiddenFiles,
          maxFileSizeBytes: maxFileSizeBytes,
        );

    final resolvedInferenceGateway =
        createInferenceGateway(
      inferenceService: inferenceService,
      inferenceGateway: inferenceGateway,
    );

    return WorkshopEngine(
      inferenceGateway: resolvedInferenceGateway,
      projectExecutor: resolvedExecutor,
    );
  }

  /// Crea il controller della Dashboard.
  ///
  /// Il controller riceve l'engine già configurato.
  ///
  /// Quando viene fornito [workspaceRootPath]:
  ///
  ///   workspaceRootPath
  ///          ↓
  ///   LocalGitWorkspaceGateway
  ///          ↓
  ///   ProjectExecutor
  ///          ↓
  ///   WorkshopEngine
  ///
  /// e contemporaneamente:
  ///
  ///   InferenceService
  ///          ↓
  ///   WorkshopInferenceProviderAdapter
  ///          ↓
  ///   WorkshopInferenceGateway
  ///          ↓
  ///   WorkshopEngine
  static WorkshopDashboardController
      createDashboardController({
    String? workspaceRootPath,
    WorkshopEngine? engine,
    WorkshopProjectExecutor? projectExecutor,
    InferenceService? inferenceService,
    WorkshopInferenceGateway? inferenceGateway,
    bool includeHiddenFiles = false,
    int maxFileSizeBytes = 10 * 1024 * 1024,
  }) {
    final resolvedEngine =
        engine ??
        createEngine(
          workspaceRootPath: workspaceRootPath,
          projectExecutor: projectExecutor,
          inferenceService: inferenceService,
          inferenceGateway: inferenceGateway,
          includeHiddenFiles: includeHiddenFiles,
          maxFileSizeBytes: maxFileSizeBytes,
        );

    return WorkshopDashboardController(
      engine: resolvedEngine,
    );
  }

  /// Crea l'intero blocco applicativo del Cantiere.
  ///
  /// Questo è il punto di ingresso generale che potrà essere utilizzato
  /// successivamente da:
  ///
  /// - Dashboard;
  /// - Assistente attraverso un contratto stabile;
  /// - A-Team;
  /// - servizi background;
  /// - altri domini della Factory.
  ///
  /// La creazione delle dipendenze NON avvia automaticamente una produzione.
  static WorkshopDashboardController create({
    String? workspaceRootPath,
    WorkshopProjectExecutor? projectExecutor,
    InferenceService? inferenceService,
    WorkshopInferenceGateway? inferenceGateway,
    WorkshopEngine? engine,
    bool includeHiddenFiles = false,
    int maxFileSizeBytes = 10 * 1024 * 1024,
  }) {
    if (engine != null) {
      return WorkshopDashboardController(
        engine: engine,
      );
    }

    return createDashboardController(
      workspaceRootPath: workspaceRootPath,
      projectExecutor: projectExecutor,
      inferenceService: inferenceService,
      inferenceGateway: inferenceGateway,
      includeHiddenFiles: includeHiddenFiles,
      maxFileSizeBytes: maxFileSizeBytes,
    );
  }

  /// Costruisce il ProjectExecutor solo quando è disponibile una root
  /// di workspace reale.
  ///
  /// Questo mantiene il factory compatibile con la fase attuale:
  /// l'app può costruire il Cantiere senza assumere arbitrariamente
  /// un percorso di progetto.
  static WorkshopProjectExecutor?
      _createOptionalProjectExecutor({
    required String? workspaceRootPath,
    required bool includeHiddenFiles,
    required int maxFileSizeBytes,
  }) {
    final normalizedPath =
        workspaceRootPath?.trim();

    if (normalizedPath == null ||
        normalizedPath.isEmpty) {
      return null;
    }

    return createProjectExecutor(
      workspaceRootPath: normalizedPath,
      includeHiddenFiles: includeHiddenFiles,
      maxFileSizeBytes: maxFileSizeBytes,
    );
  }
}

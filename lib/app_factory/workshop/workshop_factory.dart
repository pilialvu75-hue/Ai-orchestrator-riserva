import 'package:get_it/get_it.dart';

import 'package:ai_orchestrator/app_factory/workspace/local_git_workspace_gateway.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_assignments.dart';
import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_dashboard_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_engine.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_provider_adapter.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_executor.dart';

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
///   Workshop model assignment
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
/// L'infrastruttura di inferenza può essere condivisa, ma il modello,
/// il ruolo e la configurazione del Workshop vengono risolti
/// indipendentemente dall'Assistente.
final class WorkshopFactory {
  const WorkshopFactory._();

  /// Carica la configurazione persistente dei modelli del Cantiere.
  ///
  /// Il namespace di persistenza appartiene esclusivamente al Workshop.
  /// In assenza di configurazione valida vengono utilizzati i defaults
  /// definiti da [WorkshopModelAssignments].
  static Future<List<WorkshopModelAssignment>>
      loadPersistedAssignments() {
    return WorkshopModelAssignments.load();
  }

  /// Crea il gateway locale del Workspace.
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
  /// Il Cantiere riutilizza l'infrastruttura runtime esistente, ma non
  /// dovrebbe ereditare la selezione logica del modello dell'Assistente.
  ///
  /// L'isolamento del modello Workshop viene applicato dal relativo
  /// WorkshopInferenceProviderAdapter.
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

  /// Restituisce il model ID assegnato al ruolo Workshop.
  ///
  /// La configurazione è completamente separata dalla selezione
  /// dell'Assistente.
  static String resolveWorkshopModelId({
    AppAiRole role = AppAiRole.workshopOrchestrator,
    List<WorkshopModelAssignment> assignments =
        WorkshopModelAssignments.defaults,
  }) {
    if (role == AppAiRole.assistantOrchestrator) {
      throw StateError(
        'The Assistant role cannot be resolved by WorkshopFactory.',
      );
    }

    final modelId = WorkshopModelAssignments.modelIdFor(
      role,
      assignments: assignments,
    );

    if (modelId == null || modelId.trim().isEmpty) {
      throw StateError(
        'No Workshop model is assigned to role "${role.id}".',
      );
    }

    final normalizedModelId = modelId.trim();
    final model = WorkshopModelCatalogue.findById(
      normalizedModelId,
    );

    if (model == null) {
      throw StateError(
        'Workshop model "$normalizedModelId" is not present '
        'in the Workshop model catalogue.',
      );
    }

    if (!model.isWorkshopModel) {
      throw StateError(
        'Model "$normalizedModelId" is not a Workshop model.',
      );
    }

    if (!model.canServe(role)) {
      throw StateError(
        'Model "$normalizedModelId" cannot serve role "${role.id}".',
      );
    }

    return normalizedModelId;
  }

  /// Crea il provider del Cantiere con configurazione modello/ruolo propria.
  ///
  /// Questo è il confine fondamentale tra:
  ///
  ///   Assistant
  ///      ↓
  ///   propria configurazione
  ///
  /// e:
  ///
  ///   Workshop
  ///      ↓
  ///   propria configurazione
  ///
  /// I due sistemi possono condividere l'InferenceService come infrastruttura
  /// di basso livello, ma il modello del Workshop viene scelto esplicitamente
  /// dalla configurazione Workshop.
  static WorkshopInferenceProviderAdapter
      createInferenceProviderAdapter({
    InferenceService? inferenceService,
    AppAiRole role = AppAiRole.workshopOrchestrator,
    List<WorkshopModelAssignment> assignments =
        WorkshopModelAssignments.defaults,
    String? modelId,
  }) {
    final resolvedInferenceService =
        resolveInferenceService(
      inferenceService: inferenceService,
    );

    final resolvedModelId =
        modelId?.trim().isNotEmpty == true
            ? modelId!.trim()
            : resolveWorkshopModelId(
                role: role,
                assignments: assignments,
              );

    final model = WorkshopModelCatalogue.findById(
      resolvedModelId,
    );

    if (model == null) {
      throw StateError(
        'Workshop model "$resolvedModelId" is not present '
        'in the Workshop model catalogue.',
      );
    }

    if (!model.isWorkshopModel) {
      throw StateError(
        'Model "$resolvedModelId" is not a Workshop model.',
      );
    }

    if (!model.canServe(role)) {
      throw StateError(
        'Model "$resolvedModelId" cannot serve role "${role.id}".',
      );
    }

    return WorkshopInferenceProviderAdapter(
      inferenceService: resolvedInferenceService,
      role: role,
      modelId: resolvedModelId,
    );
  }

  /// Crea il gateway di inferenza del Cantiere.
  ///
  /// Se viene fornito un gateway esplicito, quello ha precedenza.
  ///
  /// In caso contrario viene costruito il provider Workshop con il
  /// modello assegnato al ruolo richiesto.
  static WorkshopInferenceGateway
      createInferenceGateway({
    InferenceService? inferenceService,
    WorkshopInferenceGateway? inferenceGateway,
    AppAiRole role = AppAiRole.workshopOrchestrator,
    List<WorkshopModelAssignment> assignments =
        WorkshopModelAssignments.defaults,
    String? modelId,
  }) {
    if (inferenceGateway != null) {
      return inferenceGateway;
    }

    final provider =
        createInferenceProviderAdapter(
      inferenceService: inferenceService,
      role: role,
      assignments: assignments,
      modelId: modelId,
    );

    return WorkshopInferenceGateway(
      provider: provider,
    );
  }

  /// Crea un WorkshopEngine già collegato al ProjectExecutor e
  /// al cervello AI del Cantiere.
  static WorkshopEngine createEngine({
    String? workspaceRootPath,
    WorkshopProjectExecutor? projectExecutor,
    InferenceService? inferenceService,
    WorkshopInferenceGateway? inferenceGateway,
    AppAiRole role = AppAiRole.workshopOrchestrator,
    List<WorkshopModelAssignment> assignments =
        WorkshopModelAssignments.defaults,
    String? modelId,
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
      role: role,
      assignments: assignments,
      modelId: modelId,
    );

    return WorkshopEngine(
      inferenceGateway: resolvedInferenceGateway,
      projectExecutor: resolvedExecutor,
    );
  }

  /// Crea il controller della Dashboard.
  static WorkshopDashboardController
      createDashboardController({
    String? workspaceRootPath,
    WorkshopEngine? engine,
    WorkshopProjectExecutor? projectExecutor,
    InferenceService? inferenceService,
    WorkshopInferenceGateway? inferenceGateway,
    AppAiRole role = AppAiRole.workshopOrchestrator,
    List<WorkshopModelAssignment> assignments =
        WorkshopModelAssignments.defaults,
    String? modelId,
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
              role: role,
              assignments: assignments,
              modelId: modelId,
              includeHiddenFiles: includeHiddenFiles,
              maxFileSizeBytes: maxFileSizeBytes,
            );

    return WorkshopDashboardController(
      engine: resolvedEngine,
    );
  }

  /// Crea l'intero blocco applicativo del Cantiere.
  ///
  /// Il chiamante può fornire esplicitamente gli assignment oppure
  /// utilizzare i defaults.
  static WorkshopDashboardController create({
    String? workspaceRootPath,
    WorkshopProjectExecutor? projectExecutor,
    InferenceService? inferenceService,
    WorkshopInferenceGateway? inferenceGateway,
    WorkshopEngine? engine,
    AppAiRole role = AppAiRole.workshopOrchestrator,
    List<WorkshopModelAssignment> assignments =
        WorkshopModelAssignments.defaults,
    String? modelId,
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
      role: role,
      assignments: assignments,
      modelId: modelId,
      includeHiddenFiles: includeHiddenFiles,
      maxFileSizeBytes: maxFileSizeBytes,
    );
  }

  /// Crea il blocco applicativo del Cantiere utilizzando la configurazione
  /// persistente dei suoi modelli.
  ///
  /// Questo metodo è asincrono perché legge SharedPreferences prima
  /// di costruire il provider di inferenza.
  ///
  /// L'Assistente non viene mai letto, modificato o sovrascritto.
  static Future<WorkshopDashboardController>
      createWithPersistedAssignments({
    String? workspaceRootPath,
    WorkshopProjectExecutor? projectExecutor,
    InferenceService? inferenceService,
    WorkshopInferenceGateway? inferenceGateway,
    WorkshopEngine? engine,
    AppAiRole role = AppAiRole.workshopOrchestrator,
    String? modelId,
    bool includeHiddenFiles = false,
    int maxFileSizeBytes = 10 * 1024 * 1024,
  }) async {
    final assignments =
        await loadPersistedAssignments();

    return create(
      workspaceRootPath: workspaceRootPath,
      projectExecutor: projectExecutor,
      inferenceService: inferenceService,
      inferenceGateway: inferenceGateway,
      engine: engine,
      role: role,
      assignments: assignments,
      modelId: modelId,
      includeHiddenFiles: includeHiddenFiles,
      maxFileSizeBytes: maxFileSizeBytes,
    );
  }

  /// Costruisce il ProjectExecutor solo quando è disponibile una root
  /// di workspace reale.
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

import '../workspace/local_git_workspace_gateway.dart';

import 'workshop_dashboard_controller.dart';
import 'workshop_engine.dart';
import 'workshop_project_executor.dart';

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
///   WorkshopProjectExecutor
///          ↓
///   LocalGitWorkspaceGateway
///          ↓
///   WorkspaceSession
///          ↓
///   VirtualWorkspace
///
/// Il factory non avvia automaticamente una produzione.
///
/// La sua responsabilità è esclusivamente costruire il blocco
/// operativo del Cantiere in modo esplicito e verificabile.
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

  /// Crea un WorkshopEngine già collegato al ProjectExecutor.
  ///
  /// Se [projectExecutor] viene fornito esplicitamente, viene usato
  /// direttamente.
  ///
  /// Altrimenti il factory costruisce automaticamente il ProjectExecutor
  /// sul Workspace locale.
  static WorkshopEngine createEngine({
    String? workspaceRootPath,
    WorkshopProjectExecutor? projectExecutor,
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

    return WorkshopEngine(
      projectExecutor: resolvedExecutor,
    );
  }

  /// Crea il controller della Dashboard.
  ///
  /// Il controller riceve l'engine già configurato.
  ///
  /// [workspaceRootPath] è opzionale per mantenere il factory utilizzabile
  /// anche quando la UI non è ancora stata collegata ad un progetto locale.
  ///
  /// Quando viene fornito:
  ///
  ///   workspaceRootPath
  ///          ↓
  ///   LocalGitWorkspaceGateway
  ///          ↓
  ///   ProjectExecutor
  ///          ↓
  ///   Engine
  ///          ↓
  ///   Controller
  static WorkshopDashboardController createDashboardController({
    String? workspaceRootPath,
    WorkshopEngine? engine,
    WorkshopProjectExecutor? projectExecutor,
    bool includeHiddenFiles = false,
    int maxFileSizeBytes = 10 * 1024 * 1024,
  }) {
    final resolvedEngine =
        engine ??
        createEngine(
          workspaceRootPath: workspaceRootPath,
          projectExecutor: projectExecutor,
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
  /// - Assistente;
  /// - A-Team;
  /// - servizi background;
  /// - altri domini della Factory.
  ///
  /// La creazione delle dipendenze non avvia alcuna produzione.
  static WorkshopDashboardController create({
    String? workspaceRootPath,
    WorkshopProjectExecutor? projectExecutor,
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

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_capability_shopping_list.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_engine.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_local_toolchain_detector.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_local_toolchain_service.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
//import 'package:ai_orchestrator/app_factory/workshop/workshop_project_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';

/// Stato osservabile del Dashboard Controller del Cantiere.
///
/// Il controller mantiene la UI separata dalla toolchain e dal motore
/// di esecuzione. La pagina può osservare questo stato senza conoscere
/// i dettagli interni del Workshop.
final class WorkshopDashboardControllerState {
  const WorkshopDashboardControllerState({
    this.requestId,
    this.projectId,
    this.projectTitle,
    this.stage,
    this.projectStatus,
    this.progress = 0,
    this.completedTasks = 0,
    this.totalTasks = 0,
    this.activeTaskId,
    this.activeTaskTitle,
    this.lastMessage,
    this.lastError,
    this.lastBuildResult,
    this.projectApproval,
    this.localToolchainInspected = false,
    this.isBusy = false,
  });

  /// Identificativo della richiesta corrente.
  final String? requestId;

  /// Identificativo del progetto corrente.
  final String? projectId;

  /// Titolo del progetto corrente.
  final String? projectTitle;

  /// Fase corrente del Workshop.
  final WorkshopStage? stage;

  /// Stato del project plan.
  final WorkshopProjectStatus? projectStatus;

  /// Avanzamento del progetto tra 0 e 1.
  final double progress;

  final int completedTasks;
  final int totalTasks;

  /// Task attualmente preparato per l'esecuzione.
  final String? activeTaskId;

  final String? activeTaskTitle;

  final String? lastMessage;
  final String? lastError;

  final WorkshopBuildResult? lastBuildResult;

  /// Explicit owner authorization granted at the project proposal boundary.
  ///
  /// This is project-scoped evidence, not permission to bypass Reviewer or
  /// validation. Production may use it only to apply changes that have already
  /// passed those guards inside the same authoritative project.
  final WorkshopProjectApprovalEvidence? projectApproval;

  /// Indica se la toolchain locale è già stata ispezionata.
  final bool localToolchainInspected;

  final bool isBusy;

  bool get hasProject => projectId != null;

  bool get hasActiveTask => activeTaskId != null;

  bool get hasError =>
      lastError != null && lastError!.trim().isNotEmpty;

  bool get hasBuildResult => lastBuildResult != null;

  bool get isProjectApproved =>
      projectApproval != null &&
      projectId != null &&
      projectApproval!.projectId == projectId;

  WorkshopDashboardControllerState copyWith({
    String? requestId,
    String? projectId,
    String? projectTitle,
    WorkshopStage? stage,
    WorkshopProjectStatus? projectStatus,
    double? progress,
    int? completedTasks,
    int? totalTasks,
    String? activeTaskId,
    String? activeTaskTitle,
    String? lastMessage,
    String? lastError,
    WorkshopBuildResult? lastBuildResult,
    WorkshopProjectApprovalEvidence? projectApproval,
    bool? localToolchainInspected,
    bool? isBusy,
    bool clearActiveTask = false,
    bool clearError = false,
    bool clearBuildResult = false,
    bool clearProjectApproval = false,
  }) {
    return WorkshopDashboardControllerState(
      requestId: requestId ?? this.requestId,
      projectId: projectId ?? this.projectId,
      projectTitle: projectTitle ?? this.projectTitle,
      stage: stage ?? this.stage,
      projectStatus: projectStatus ?? this.projectStatus,
      progress: progress ?? this.progress,
      completedTasks: completedTasks ?? this.completedTasks,
      totalTasks: totalTasks ?? this.totalTasks,
      activeTaskId: clearActiveTask
          ? null
          : activeTaskId ?? this.activeTaskId,
      activeTaskTitle: clearActiveTask
          ? null
          : activeTaskTitle ?? this.activeTaskTitle,
      lastMessage: lastMessage ?? this.lastMessage,
      lastError: clearError ? null : lastError ?? this.lastError,
      lastBuildResult: clearBuildResult
          ? null
          : lastBuildResult ?? this.lastBuildResult,
      projectApproval: clearProjectApproval
          ? null
          : projectApproval ?? this.projectApproval,
      localToolchainInspected:
          localToolchainInspected ?? this.localToolchainInspected,
      isBusy: isBusy ?? this.isBusy,
    );
  }
}

/// Controller applicativo della Dashboard del Cantiere.
///
/// Responsabilità:
///
///   Dashboard UI
///        ↓
///   WorkshopDashboardController
///        ↓
///   WorkshopEngine
///        ↓
///   WorkshopProjectExecutor
///        ↓
///   WorkspaceSession
///
/// Il controller espone inoltre l'accesso controllato a:
///
///   LocalToolchainService
///        ↓
///   BuildLab
///
/// Il controller NON:
///
/// - contiene widget Flutter;
/// - modifica direttamente il repository;
/// - esegue shell arbitrarie;
/// - sceglie provider AI;
/// - bypassa Execution Guard;
/// - applica automaticamente modifiche;
/// - finge una build riuscita quando non esiste un provider reale.
///
/// È il punto di integrazione progressivo tra la UI del Cantiere
/// e la toolchain reale.
final class WorkshopDashboardController extends ChangeNotifier {
  static int _lastRequestIdentityMicros = 0;

  static int _nextRequestIdentityMicros() {
    final now = DateTime.now().microsecondsSinceEpoch;
    if (now > _lastRequestIdentityMicros) {
      _lastRequestIdentityMicros = now;
    } else {
      _lastRequestIdentityMicros += 1;
    }
    return _lastRequestIdentityMicros;
  }

  WorkshopDashboardController({
    required WorkshopEngine engine,
    WorkshopLocalToolchainService? localToolchainService,
    WorkshopBuildLab? buildLab,
  })  : _engine = engine,
        _localToolchainService =
            localToolchainService ?? WorkshopLocalToolchainService(),
        _buildLab = buildLab ?? WorkshopBuildLab() {
    _stageSubscription = _engine.stageStream.listen(
      _handleStageEvent,
    );
  }

  final WorkshopEngine _engine;

  final WorkshopLocalToolchainService _localToolchainService;

  final WorkshopBuildLab _buildLab;

  WorkshopDashboardControllerState _state =
      const WorkshopDashboardControllerState();

  StreamSubscription<WorkshopStageEvent>? _stageSubscription;

  bool _disposed = false;

  WorkshopDashboardControllerState get state => _state;

  WorkshopEngine get engine => _engine;

  WorkshopLocalToolchainService get localToolchainService =>
      _localToolchainService;

  WorkshopBuildLab get buildLab => _buildLab;

  /// Rebuilds a durable Cantiere production without restoring any ephemeral
  /// in-memory diff or approval flag.
  ///
  /// The project/request identity and plan progress are retained. If a task was
  /// active when the process stopped, a fresh WorkspaceSession is opened on the
  /// same real workspace and the task returns to implementation so the guarded
  /// inference/review/approval cycle must run again.
  Future<WorkshopProjectPlan> restoreProduction({
    required WorkshopRequest request,
    required WorkshopProjectPlan plan,
    String? activeTaskId,
    WorkshopProjectApprovalEvidence? projectApproval,
  }) async {
    _ensureNotDisposed();

    if (_state.requestId != null) {
      throw StateError(
        'Cannot restore a Workshop production while another production is active.',
      );
    }

    final requestId = request.id.trim();

    if (requestId.isEmpty) {
      throw ArgumentError.value(
        request.id,
        'request.id',
        'Recovered Workshop request id cannot be empty.',
      );
    }

    if (plan.id != 'project:$requestId') {
      throw StateError(
        'Recovered Workshop project "${plan.id}" does not match request "$requestId".',
      );
    }

    if (plan.assumptions.isNotEmpty || plan.risks.isNotEmpty) {
      throw StateError(
        'The current Workshop engine cannot safely restore non-empty assumptions or risks.',
      );
    }

    if (projectApproval != null &&
        projectApproval.projectId.trim() != plan.id.trim()) {
      throw StateError(
        'Recovered Workshop project approval does not belong to '
        'project "${plan.id}".',
      );
    }

    _engine.createProjectPlan(
      request,
      domain: plan.domain,
      requirements: plan.requirements,
      constraints: plan.constraints,
      technologies: plan.technologies,
      hardware: plan.hardware,
      deliverables: plan.deliverables,
      validationCriteria: plan.validationCriteria,
      phases: plan.phases
          .map((phase) => phase.copyWith())
          .toList(growable: false),
      tasks: plan.tasks
          .map((task) => task.copyWith())
          .toList(growable: false),
    );

    final restoredPlan = _engine.planOf(requestId);

    if (restoredPlan == null) {
      throw StateError(
        'WorkshopEngine did not restore project "$requestId".',
      );
    }

    restoredPlan.status = plan.status;
    restoredPlan.updatedAt = plan.updatedAt;
    if (restoredPlan.status == WorkshopProjectStatus.completed) {
      _engine.restoreCompletedProjectStage(requestId);
    }

    String? restoredActiveTaskId;
    String? restoredActiveTaskTitle;

    final normalizedActiveTaskId = activeTaskId?.trim();

    if (normalizedActiveTaskId != null &&
        normalizedActiveTaskId.isNotEmpty &&
        plan.status != WorkshopProjectStatus.completed &&
        plan.status != WorkshopProjectStatus.cancelled) {
      final task = restoredPlan.taskById(normalizedActiveTaskId);

      if (task == null) {
        throw StateError(
          'Recovered Workshop task "$normalizedActiveTaskId" does not exist.',
        );
      }

      if (!task.completed) {
        await _engine.prepareProjectTask(
          requestId,
          normalizedActiveTaskId,
        );
        restoredActiveTaskId = normalizedActiveTaskId;
        restoredActiveTaskTitle = task.title;
      }
    }

    final restoredStage = restoredActiveTaskId != null
        ? WorkshopStage.implementation
        : switch (restoredPlan.status) {
            WorkshopProjectStatus.completed => WorkshopStage.completed,
            WorkshopProjectStatus.cancelled => WorkshopStage.cancelled,
            WorkshopProjectStatus.blocked => WorkshopStage.blocked,
            WorkshopProjectStatus.review => WorkshopStage.review,
            WorkshopProjectStatus.validation => WorkshopStage.validation,
            _ => WorkshopStage.planning,
          };

    _updateState(
      WorkshopDashboardControllerState(
        requestId: requestId,
        projectId: restoredPlan.id,
        projectTitle: restoredPlan.title,
        stage: restoredStage,
        projectStatus: restoredPlan.status,
        progress: restoredPlan.progress,
        completedTasks: restoredPlan.completedTasks,
        totalTasks: restoredPlan.totalTasks,
        activeTaskId: restoredActiveTaskId,
        activeTaskTitle: restoredActiveTaskTitle,
        projectApproval: projectApproval,
        lastMessage: restoredActiveTaskId == null
            ? 'Produzione del Cantiere recuperata dal checkpoint.'
            : 'Produzione recuperata: il task attivo è pronto per essere rieseguito in sicurezza.',
        isBusy: false,
      ),
    );

    return restoredPlan;
  }

  /// Avvia una nuova produzione creando:
  ///
  ///   richiesta
  ///      ↓
  ///   project plan
  ///      ↓
  ///   primo task
  ///
  /// Non esegue ancora il task.
  ///
  /// Questo metodo prepara il Cantiere senza introdurre
  /// side-effect sul repository reale.
  WorkshopProjectPlan startProduction({
    required String title,
    required String instruction,
    List<String> requirements = const <String>[],
    List<String> constraints = const <String>[],
    List<String> technologies = const <String>[],
    List<String> deliverables = const <String>[],
    List<String> validationCriteria = const <String>[],
    List<String> context = const <String>[],
  }) {
    _ensureNotDisposed();

    final normalizedTitle = title.trim();
    final normalizedInstruction = instruction.trim();

    if (normalizedTitle.isEmpty) {
      throw ArgumentError.value(
        title,
        'title',
        'Production title cannot be empty.',
      );
    }

    if (normalizedInstruction.isEmpty) {
      throw ArgumentError.value(
        instruction,
        'instruction',
        'Production instruction cannot be empty.',
      );
    }

    final requestId = 'dashboard:${_nextRequestIdentityMicros()}';

    final request = WorkshopRequest(
      id: requestId,
      title: normalizedTitle,
      instruction: normalizedInstruction,
      source: WorkshopRequestSource.workshop,
      operation: WorkshopOperation.create,
      targetFiles: const <String>[],
      constraints: constraints,
      context: List<String>.unmodifiable(
        context
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty),
      ),
    );

    _engine.createProjectPlan(
      request,
      domain: WorkshopProjectDomain.software,
      requirements: requirements,
      constraints: constraints,
      technologies: technologies,
      deliverables: deliverables,
      validationCriteria: validationCriteria,
      phases: <WorkshopProjectPhase>[
        WorkshopProjectPhase(
          id: 'phase:implementation',
          title: 'Implementazione',
          description:
              'Preparazione ed esecuzione della prima unità '
              'di lavoro del progetto.',
          taskIds: const <String>[
            'task:initial-implementation',
          ],
          validationCriteria: validationCriteria,
        ),
      ],
      tasks: <WorkshopProjectTask>[
        WorkshopProjectTask(
          id: 'task:initial-implementation',
          title: 'Implementazione iniziale',
          description: normalizedInstruction,
          phaseId: 'phase:implementation',
          affectedPaths: const <String>[],
          validationCriteria: validationCriteria,
        ),
      ],
    );

    final plan = _engine.planOf(requestId);

    if (plan == null) {
      throw StateError(
        'WorkshopEngine created no project plan for '
        'request "$requestId".',
      );
    }

    _updateState(
      _state.copyWith(
        requestId: requestId,
        projectId: plan.id,
        projectTitle: plan.title,
        projectStatus: plan.status,
        progress: plan.progress,
        completedTasks: plan.completedTasks,
        totalTasks: plan.totalTasks,
        lastMessage: 'Produzione preparata nel Cantiere.',
        clearError: true,
        clearBuildResult: true,
        clearProjectApproval: true,
        clearActiveTask: true,
        isBusy: false,
      ),
    );

    return plan;
  }

  /// Records the owner's explicit approval of the current project proposal.
  ///
  /// This authorization is deliberately project-scoped. It allows the
  /// production UI to continue validated tasks without asking the owner to
  /// approve every generated file, but it never makes unreviewed or invalid
  /// changes applicable.
  WorkshopProjectApprovalEvidence approveCurrentProject({
    String approvedBy = 'owner',
    String? derivedFromApprovalId,
  }) {
    _ensureNotDisposed();

    final projectId = _state.projectId?.trim();
    if (projectId == null || projectId.isEmpty) {
      throw StateError(
        'Cannot approve Workshop production without an active project.',
      );
    }

    final existing = _state.projectApproval;
    if (existing != null && existing.projectId == projectId) {
      return existing;
    }

    final now = DateTime.now().toUtc();
    final normalizedDerivedApprovalId = derivedFromApprovalId?.trim();
    final approval = WorkshopProjectApprovalEvidence(
      projectId: projectId,
      approvalId: 'approval:$projectId:${now.microsecondsSinceEpoch}',
      approvedAt: now,
      approvedBy: approvedBy.trim().isEmpty ? 'owner' : approvedBy.trim(),
      derivedFromApprovalId:
          normalizedDerivedApprovalId == null ||
                  normalizedDerivedApprovalId.isEmpty
              ? null
              : normalizedDerivedApprovalId,
    );

    _updateState(
      _state.copyWith(
        projectApproval: approval,
        lastMessage:
            'Proposta approvata: produzione autonoma autorizzata entro i gate.',
        clearError: true,
      ),
    );

    return approval;
  }

  /// Prepara il prossimo task del progetto.
  ///
  /// Questa è la prima vera porta verso WorkspaceSession.
  ///
  /// Se WorkshopEngine non possiede un WorkshopProjectExecutor,
  /// l'errore viene riportato senza modificare lo stato del repository.
  Future<WorkspaceSession?> prepareNextTask({
    WorkshopBrief? brief,
  }) async {
    _ensureNotDisposed();

    final requestId = _state.requestId;

    if (requestId == null) {
      throw StateError(
        'No active Workshop production exists.',
      );
    }

    _setBusy(true);

    try {
      final session = await _engine.prepareNextProjectTask(
        requestId,
        brief: brief,
      );

      if (session == null) {
        _refreshProjectState(
          message: 'Non ci sono altri task eseguibili.',
          clearActiveTask: true,
        );

        return null;
      }

      final summary = _engine.projectSummary(requestId);

      _updateState(
        _state.copyWith(
          projectStatus: summary?.status,
          progress: summary?.progress ?? _state.progress,
          completedTasks:
              summary?.completedTasks ?? _state.completedTasks,
          totalTasks: summary?.totalTasks ?? _state.totalTasks,
          activeTaskId: summary?.nextTaskId,
          activeTaskTitle: summary?.nextTaskTitle,
          lastMessage: 'Task preparato nello spazio di lavoro.',
          clearError: true,
          isBusy: false,
        ),
      );

      return session;
    } catch (error) {
      _setError(
        'Preparazione del task fallita: $error',
      );
      rethrow;
    }
  }

  /// Prepara esplicitamente un task già presente nel piano.
  Future<WorkspaceSession> prepareTask(
    String taskId, {
    WorkshopBrief? brief,
  }) async {
    _ensureNotDisposed();

    final requestId = _state.requestId;

    if (requestId == null) {
      throw StateError(
        'No active Workshop production exists.',
      );
    }

    final normalizedTaskId = taskId.trim();

    if (normalizedTaskId.isEmpty) {
      throw ArgumentError.value(
        taskId,
        'taskId',
        'Task id cannot be empty.',
      );
    }

    _setBusy(true);

    try {
      final session = await _engine.prepareProjectTask(
        requestId,
        normalizedTaskId,
        brief: brief,
      );

      final summary = _engine.projectSummary(requestId);

      _updateState(
        _state.copyWith(
          projectStatus: summary?.status,
          progress: summary?.progress ?? _state.progress,
          completedTasks:
              summary?.completedTasks ?? _state.completedTasks,
          totalTasks: summary?.totalTasks ?? _state.totalTasks,
          activeTaskId: normalizedTaskId,
          activeTaskTitle: _engine
              .planOf(requestId)
              ?.taskById(
                normalizedTaskId,
              )
              ?.title,
          lastMessage:
              'Task selezionato e preparato nello spazio di lavoro.',
          clearError: true,
          isBusy: false,
        ),
      );

      return session;
    } catch (error) {
      _setError(
        'Preparazione del task fallita: $error',
      );
      rethrow;
    }
  }

  /// Ispeziona la toolchain locale.
  ///
  /// Non esegue build e non modifica il progetto.
  Future<WorkshopLocalToolchainReport>
      inspectLocalToolchain() async {
    _ensureNotDisposed();

    _setBusy(true);

    try {
      final report = await _localToolchainService.inspect();

      _updateState(
        _state.copyWith(
          localToolchainInspected: true,
          lastMessage: 'Toolchain locale ispezionata.',
          clearError: true,
          isBusy: false,
        ),
      );

      return report;
    } catch (error) {
      _setError(
        'Ispezione della toolchain fallita: $error',
      );
      rethrow;
    }
  }

  /// Restituisce la decisione corrente della toolchain
  /// per un target specifico.
  WorkshopLocalToolchainDecision localToolchainDecision(
    WorkshopBuildTarget target,
  ) {
    _ensureNotDisposed();

    return _localToolchainService.decisionFor(target);
  }

  /// Avvia una build attraverso il Build Lab.
  ///
  /// IMPORTANTE:
  /// il controller non considera automaticamente riuscita
  /// una build.
  ///
  /// Se il Build Lab non dispone di un provider reale,
  /// restituirà il risultato esplicito di provider non disponibile.
  Future<WorkshopBuildResult> buildProject({
    required String projectPath,
    required WorkshopBuildTarget target,
    WorkshopBuildExecutionMode mode =
        WorkshopBuildExecutionMode.automatic,
    String? projectId,
    bool runTests = true,
    bool runAnalyzer = true,
    bool runFormatter = true,
    bool cleanBuild = false,
    List<String> arguments = const <String>[],
  }) async {
    _ensureNotDisposed();

    final normalizedPath = projectPath.trim();

    if (normalizedPath.isEmpty) {
      throw ArgumentError.value(
        projectPath,
        'projectPath',
        'Project path cannot be empty.',
      );
    }

    final resolvedProjectId =
        projectId ?? _state.projectId ?? 'workshop-project';

    final requestId =
        'build:$resolvedProjectId:${DateTime.now().microsecondsSinceEpoch}';

    final request = WorkshopBuildRequest(
      id: requestId,
      projectId: resolvedProjectId,
      projectPath: normalizedPath,
      target: target,
      mode: mode,
      runTests: runTests,
      runAnalyzer: runAnalyzer,
      runFormatter: runFormatter,
      cleanBuild: cleanBuild,
      arguments: arguments,
    );

    _setBusy(true);

    try {
      final result = await _buildLab.build(request);

      _updateState(
        _state.copyWith(
          lastBuildResult: result,
          lastMessage: result.message ?? 'Build completata.',
          clearError: result.succeeded,
          isBusy: false,
        ),
      );

      return result;
    } catch (error) {
      _setError(
        'Build fallita: $error',
      );
      rethrow;
    }
  }

  /// Restituisce il riepilogo del progetto attivo.
  WorkshopProjectSummary? get projectSummary {
    final requestId = _state.requestId;

    if (requestId == null) {
      return null;
    }

    return _engine.projectSummary(
      requestId,
    );
  }

  /// Segna il task corrente come completato.
  ///
  /// WorkshopEngine delega la validazione a
  /// WorkshopProjectExecutor, che richiede una
  /// WorkspaceSession realmente completata.
  void completeActiveTask() {
    _ensureNotDisposed();

    final requestId = _state.requestId;
    final taskId = _state.activeTaskId;

    if (requestId == null || taskId == null) {
      throw StateError(
        'No active Workshop task exists.',
      );
    }

    try {
      _engine.completeProjectTask(
        requestId,
        taskId,
      );

      _refreshProjectState(
        message: 'Task completato nel piano del Cantiere.',
        clearActiveTask: true,
      );
    } catch (error) {
      _setError(
        'Impossibile completare il task: $error',
      );
      rethrow;
    }
  }

  /// Annulla la produzione corrente.
  void cancelProduction() {
    _ensureNotDisposed();

    final requestId = _state.requestId;

    if (requestId == null) {
      return;
    }

    _engine.cancel(requestId);

    _updateState(
      _state.copyWith(
        projectStatus: WorkshopProjectStatus.cancelled,
        lastMessage: 'Produzione annullata.',
        clearActiveTask: true,
        clearError: true,
        clearProjectApproval: true,
        isBusy: false,
      ),
    );
  }

  /// Pulisce la produzione corrente dal motore.
  void forgetProduction() {
    _ensureNotDisposed();

    final requestId = _state.requestId;

    if (requestId != null) {
      _engine.forget(requestId);
    }

    _updateState(
      const WorkshopDashboardControllerState(),
    );
  }

  void _handleStageEvent(
    WorkshopStageEvent event,
  ) {
    if (_disposed) {
      return;
    }

    final requestId = _state.requestId;

    if (requestId == null) {
      return;
    }

    final currentStage = _engine.stageOf(requestId);

    if (currentStage == null) {
      return;
    }

    _updateState(
      _state.copyWith(
        stage: currentStage,
        isBusy: false,
      ),
    );
  }

  void _refreshProjectState({
    String? message,
    bool clearActiveTask = false,
  }) {
    final requestId = _state.requestId;

    if (requestId == null) {
      return;
    }

    final summary = _engine.projectSummary(requestId);

    _updateState(
      _state.copyWith(
        projectStatus: summary?.status,
        progress: summary?.progress ?? _state.progress,
        completedTasks:
            summary?.completedTasks ?? _state.completedTasks,
        totalTasks: summary?.totalTasks ?? _state.totalTasks,
        activeTaskId: summary?.nextTaskId,
        activeTaskTitle: summary?.nextTaskTitle,
        lastMessage: message ?? _state.lastMessage,
        clearActiveTask: clearActiveTask,
        clearError: true,
        isBusy: false,
      ),
    );
  }

  void _setBusy(
    bool busy,
  ) {
    _updateState(
      _state.copyWith(
        isBusy: busy,
        clearError: busy,
      ),
    );
  }

  void _setError(
    String message,
  ) {
    _updateState(
      _state.copyWith(
        lastError: message,
        lastMessage: null,
        isBusy: false,
      ),
    );
  }

  void _updateState(
    WorkshopDashboardControllerState nextState,
  ) {
    if (_disposed) {
      return;
    }

    _state = nextState;
    notifyListeners();
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError(
        'WorkshopDashboardController has been disposed.',
      );
    }
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }

    _disposed = true;

    _stageSubscription?.cancel();
    _stageSubscription = null;

    // Il controller non possiede Engine, BuildLab o ToolchainService:
    // non li dispone automaticamente.
    super.dispose();
  }
}

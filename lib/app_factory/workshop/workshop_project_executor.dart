import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';

/// Esecutore del piano di progetto del Cantiere.
///
/// Questo componente collega:
///
///   WorkshopProjectPlan
///          ↓
///   WorkshopProjectExecutor
///          ↓
///   WorkspaceSession
///          ↓
///   VirtualWorkspace
///          ↓
///   diff / review / validation / approval / apply
///
/// Il ProjectPlan descrive il lavoro.
/// Il ProjectExecutor decide quale parte del piano è pronta per essere
/// eseguita.
/// La WorkspaceSession protegge il repository reale.
///
/// IMPORTANTE:
/// - non chiama direttamente un LLM;
/// - non modifica GitHub direttamente;
/// - non esegue commit;
/// - non esegue push;
/// - non applica automaticamente le modifiche.
///
/// L'esecuzione reale rimane sempre protetta dal ciclo di approvazione
/// della WorkspaceSession.
typedef WorkshopProjectGatewayFactory = GitWorkspaceGateway Function(
  String projectId,
);
typedef WorkshopProjectWorkspacePathResolver = String Function(
  String projectId,
);

final class WorkshopProjectExecutor {
  WorkshopProjectExecutor({
    required GitWorkspaceGateway gateway,
    WorkshopProjectGatewayFactory? projectGatewayFactory,
    WorkshopProjectWorkspacePathResolver? projectWorkspacePathResolver,
  })  : _gateway = gateway,
        _projectGatewayFactory = projectGatewayFactory,
        _projectWorkspacePathResolver = projectWorkspacePathResolver;

  final GitWorkspaceGateway _gateway;
  final WorkshopProjectGatewayFactory? _projectGatewayFactory;
  final WorkshopProjectWorkspacePathResolver? _projectWorkspacePathResolver;

  final Map<String, GitWorkspaceGateway> _projectGateways =
      <String, GitWorkspaceGateway>{};
  final Map<String, WorkspaceSession> _sessions =
      <String, WorkspaceSession>{};

  String? _activeProjectId;

  /// Sessioni Workspace attualmente associate ai task del progetto.
  List<WorkspaceSession> get sessions =>
      List.unmodifiable(_sessions.values);

  /// Sessione associata a un task del progetto attualmente attivo.
  WorkspaceSession? sessionForTask(String taskId) {
    final normalizedTaskId = taskId.trim();
    if (normalizedTaskId.isEmpty) return null;
    return _sessions[normalizedTaskId];
  }

  /// Directory fisica autorevole del progetto, quando la composizione
  /// persistente usa workspace isolate per progetto.
  String? workspacePathForProject(String projectId) {
    final resolver = _projectWorkspacePathResolver;
    if (resolver == null) return null;
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return null;
    return resolver(normalizedProjectId);
  }

  /// Prepara il prossimo task eseguibile del progetto.
  ///
  /// Non modifica alcun file.
  ///
  /// Restituisce null quando:
  /// - non esistono task eseguibili;
  /// - tutti i task sono completati;
  /// - tutte le dipendenze rimanenti sono bloccate.
  Future<WorkspaceSession?> prepareNextTask(
    WorkshopProjectPlan plan, {
    WorkshopRequest? projectRequest,
    WorkshopBrief? brief,
  }) async {
    _activateProject(plan.id);

    final task = plan.nextAvailableTask;

    if (task == null) {
      return null;
    }

    final existing = _sessions[task.id];

    if (existing != null) {
      return existing;
    }

    final request = WorkshopRequest(
      id: 'workshop-task:${plan.id}:${task.id}',
      title: task.title,
      instruction: task.description,
      source: WorkshopRequestSource.workshop,
      operation: _operationForTask(
        task,
        projectRequest: projectRequest,
      ),
      projectPath: null,
      targetFiles: task.affectedPaths,
      constraints: <String>[
        if (task.validationCriteria.isNotEmpty)
          'Task acceptance: ${task.validationCriteria.join(' | ')}',
        ...WorkshopConstraints.defaults.map(
          (constraint) => constraint.description,
        ),
        ...plan.constraints,
      ],
      context: <String>[
        if (task.validationCriteria.isNotEmpty)
          'Task acceptance criteria: ${task.validationCriteria.join(' | ')}',
        if (task.affectedPaths.isNotEmpty)
          'Task target files: ${task.affectedPaths.join(' | ')}',
        ...?projectRequest?.context,
        'Project: ${plan.title}',
        'Project goal: ${plan.goal}',
        'Project domain: ${plan.domain.name}',
        'Phase: ${task.phaseId}',
        if (plan.requirements.isNotEmpty)
          'Requirements: ${plan.requirements.join(' | ')}',
        if (plan.technologies.isNotEmpty)
          'Technologies: ${plan.technologies.join(' | ')}',
        if (plan.hardware.isNotEmpty)
          'Hardware: ${plan.hardware.join(' | ')}',
      ],
    );

    final session = WorkspaceSession(
      request: request,
      gateway: _gatewayForProject(plan.id),
      brief: brief,
    );

    _sessions[task.id] = session;

    await session.initialize();

    return session;
  }

  /// Prepara un task specifico.
  ///
  /// Utile quando la UI del Cantiere permette all'utente di scegliere
  /// esplicitamente quale task eseguire.
  Future<WorkspaceSession> prepareTask(
    WorkshopProjectPlan plan,
    String taskId, {
    WorkshopRequest? projectRequest,
    WorkshopBrief? brief,
  }) async {
    final task = plan.taskById(taskId);

    if (task == null) {
      throw ArgumentError.value(
        taskId,
        'taskId',
        'The requested Workshop project task does not exist.',
      );
    }

    if (task.completed) {
      throw StateError(
        'The Workshop project task "$taskId" is already completed.',
      );
    }

    if (plan.isTaskBlocked(task)) {
      throw StateError(
        'The Workshop project task "$taskId" still has incomplete dependencies.',
      );
    }

    _activateProject(plan.id);

    final existing = _sessions[task.id];

    if (existing != null) {
      return existing;
    }

    final request = WorkshopRequest(
      id: 'workshop-task:${plan.id}:${task.id}',
      title: task.title,
      instruction: task.description,
      source: WorkshopRequestSource.workshop,
      operation: _operationForTask(
        task,
        projectRequest: projectRequest,
      ),
      targetFiles: task.affectedPaths,
      constraints: <String>[
        if (task.validationCriteria.isNotEmpty)
          'Task acceptance: ${task.validationCriteria.join(' | ')}',
        ...WorkshopConstraints.defaults.map(
          (constraint) => constraint.description,
        ),
        ...plan.constraints,
      ],
      context: <String>[
        if (task.validationCriteria.isNotEmpty)
          'Task acceptance criteria: ${task.validationCriteria.join(' | ')}',
        if (task.affectedPaths.isNotEmpty)
          'Task target files: ${task.affectedPaths.join(' | ')}',
        ...?projectRequest?.context,
        'Project: ${plan.title}',
        'Project goal: ${plan.goal}',
        'Project domain: ${plan.domain.name}',
        'Phase: ${task.phaseId}',
        if (plan.requirements.isNotEmpty)
          'Requirements: ${plan.requirements.join(' | ')}',
        if (plan.technologies.isNotEmpty)
          'Technologies: ${plan.technologies.join(' | ')}',
        if (plan.hardware.isNotEmpty)
          'Hardware: ${plan.hardware.join(' | ')}',
      ],
    );

    final session = WorkspaceSession(
      request: request,
      gateway: _gatewayForProject(plan.id),
      brief: brief,
    );

    _sessions[task.id] = session;

    await session.initialize();

    return session;
  }

  /// Applica il workspace di un task soltanto dopo l'approvazione esplicita.
  ///
  /// Il metodo non duplica i guardrail: [WorkspaceSession.apply] rimane
  /// l'unico punto che verifica stato approved + autorizzazione e che
  /// materializza il VirtualWorkspace sul gateway reale.
  ///
  /// Non esegue commit, push o Pull Request.
  Future<WorkspaceSession> applyApprovedTask(
    String taskId,
  ) async {
    final normalizedTaskId = taskId.trim();

    if (normalizedTaskId.isEmpty) {
      throw ArgumentError.value(
        taskId,
        'taskId',
        'Task id cannot be empty.',
      );
    }

    final session = _sessions[normalizedTaskId];

    if (session == null) {
      throw StateError(
        'No WorkspaceSession exists for task "$normalizedTaskId".',
      );
    }

    await session.apply();

    return session;
  }

  /// Segna un task come completato dopo che la relativa WorkspaceSession
  /// ha terminato correttamente il proprio ciclo.
  ///
  /// Il metodo non modifica direttamente il piano finché la sessione non
  /// è effettivamente [WorkspaceSessionStatus.completed].
  void completeTask(
    WorkshopProjectPlan plan,
    String taskId,
  ) {
    _activateProject(plan.id);
    final task = plan.taskById(taskId);

    if (task == null) {
      throw ArgumentError.value(
        taskId,
        'taskId',
        'The requested Workshop project task does not exist.',
      );
    }

    final session = _sessions[taskId];

    if (session == null) {
      throw StateError(
        'No WorkspaceSession exists for task "$taskId".',
      );
    }

    if (!session.isCompleted) {
      throw StateError(
        'Task "$taskId" cannot be completed before its workspace session '
        'is completed.',
      );
    }

    task.completed = true;

    _refreshPlanStatus(plan);
  }

  /// Blocca il task e la relativa sessione.
  void blockTask(
    WorkshopProjectPlan plan,
    String taskId,
    String reason,
  ) {
    _activateProject(plan.id);
    final task = plan.taskById(taskId);

    if (task == null) {
      throw ArgumentError.value(
        taskId,
        'taskId',
        'The requested Workshop project task does not exist.',
      );
    }

    final session = _sessions[taskId];

    if (session != null) {
      session.block(reason);
    }

    final phase = plan.phaseById(task.phaseId);

    if (phase != null) {
      phase.status = WorkshopProjectPhaseStatus.blocked;
    }

    plan.status = WorkshopProjectStatus.blocked;
  }

  /// Restituisce le sessioni che possono essere mostrate alla UI.
  List<WorkspaceSessionSummary> get summaries {
    return List.unmodifiable(
      _sessions.values.map(
        (session) => session.summary,
      ),
    );
  }

  /// Elimina il riferimento a una sessione completata o cancellata.
  ///
  /// Non elimina il progetto e non modifica il repository.
  void forgetTaskSession(String taskId) {
    final session = _sessions[taskId];

    if (session == null) {
      return;
    }

    if (!session.isCompleted && !session.isCancelled) {
      throw StateError(
        'Only completed or cancelled task sessions can be forgotten.',
      );
    }

    _sessions.remove(taskId);
  }

  /// Cancella tutte le sessioni non ancora applicate.
  ///
  /// Il repository reale non viene modificato.
  void cancelActiveSessions() {
    for (final session in _sessions.values) {
      if (session.isCompleted ||
          session.isCancelled ||
          session.isBlocked) {
        continue;
      }

      session.cancel();
    }
  }

  void _activateProject(String projectId) {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      throw ArgumentError.value(
        projectId,
        'projectId',
        'Project id cannot be empty.',
      );
    }

    if (_activeProjectId == normalizedProjectId) {
      return;
    }

    // WorkspaceSession objects are runtime state, not durable project state.
    // Recovery reconstructs them from the selected project's persisted plan.
    // Never let standard task ids (e.g. task:initial-implementation) reuse a
    // session that belonged to a different project.
    _sessions.clear();
    _activeProjectId = normalizedProjectId;
  }

  GitWorkspaceGateway _gatewayForProject(String projectId) {
    final factory = _projectGatewayFactory;
    if (factory == null) {
      return _gateway;
    }
    final normalizedProjectId = projectId.trim();
    return _projectGateways.putIfAbsent(
      normalizedProjectId,
      () => factory(normalizedProjectId),
    );
  }

  /// Determina l'operazione Workshop più appropriata per un task.
  WorkshopOperation _operationForTask(
    WorkshopProjectTask task, {
    WorkshopRequest? projectRequest,
  }) {
    // Standard production tasks have explicit lifecycle semantics. Never infer
    // them from user-controlled project names/goals (for example "Contatore
    // Test"), because words such as Test/Build/Fix are valid product names.
    if (task.id == 'task:acceptance-verification') {
      return WorkshopOperation.validate;
    }

    if (task.title == 'Correzione build mirata' ||
        task.description.toUpperCase().startsWith('BUILD REPAIR ATTEMPT:')) {
      return WorkshopOperation.fix;
    }

    if (task.id == 'task:initial-implementation' &&
        projectRequest != null) {
      return projectRequest.operation;
    }

    // Legacy/generic tasks still need a deterministic fallback. Classify only
    // task-owned text and exclude the appended user project goal.
    final description = task.description;
    const projectGoalMarker = 'Project goal:';
    final markerIndex = description.indexOf(projectGoalMarker);
    final taskOwnedDescription = markerIndex < 0
        ? description
        : description.substring(0, markerIndex);
    final text =
        '${task.title} $taskOwnedDescription'.toLowerCase();

    final words = RegExp(r'[a-z0-9_]+')
        .allMatches(text)
        .map((match) => match.group(0)!)
        .toSet();
    bool hasWord(String word) => words.contains(word);

    if (hasWord('fix') ||
        hasWord('bug') ||
        hasWord('errore') ||
        hasWord('crash')) {
      return WorkshopOperation.fix;
    }

    if (hasWord('refactor') || hasWord('refactoring')) {
      return WorkshopOperation.refactor;
    }

    if (hasWord('optim') ||
        hasWord('performance') ||
        hasWord('latency')) {
      return WorkshopOperation.optimize;
    }

    if (hasWord('remove') ||
        hasWord('delete') ||
        hasWord('elimina')) {
      return WorkshopOperation.remove;
    }

    if (hasWord('modify') ||
        hasWord('update') ||
        hasWord('change') ||
        hasWord('modifica')) {
      return WorkshopOperation.modify;
    }

    if (hasWord('validate') ||
        hasWord('test') ||
        hasWord('build')) {
      return WorkshopOperation.validate;
    }

    return WorkshopOperation.create;
  }

  /// Aggiorna lo stato globale del progetto in base alle fasi completate.
  void _refreshPlanStatus(
    WorkshopProjectPlan plan,
  ) {
    for (final phase in plan.phases) {
      final phaseTasks = plan.tasksForPhase(phase.id);

      if (phaseTasks.isEmpty) {
        continue;
      }

      final allCompleted =
          phaseTasks.every((task) => task.completed);

      if (allCompleted) {
        phase.status =
            WorkshopProjectPhaseStatus.completed;
        continue;
      }

      if (phase.status == WorkshopProjectPhaseStatus.blocked) {
        continue;
      }

      phase.status = WorkshopProjectPhaseStatus.inProgress;
    }

    if (plan.phases.isNotEmpty &&
        plan.phases.every(
          (phase) =>
              phase.status ==
              WorkshopProjectPhaseStatus.completed,
        )) {
      plan.status =
          WorkshopProjectStatus.completed;
      return;
    }

    if (plan.phases.any(
      (phase) =>
          phase.status ==
          WorkshopProjectPhaseStatus.blocked,
    )) {
      plan.status =
          WorkshopProjectStatus.blocked;
      return;
    }

    if (plan.tasks.isNotEmpty) {
      plan.status =
          WorkshopProjectStatus.inProgress;
    }
  }
}

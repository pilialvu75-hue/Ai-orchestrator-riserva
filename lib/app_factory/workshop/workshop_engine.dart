import 'dart:async';

import 'package:ai_orchestrator/app_factory/collaboration/collaboration_bus.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';

/// Motore centrale del Cantiere.
///
/// Il WorkshopEngine coordina il ciclo di vita di una richiesta e collega
/// progressivamente:
///
///   richiesta
///      ↓
///   analisi
///      ↓
///   pianificazione
///      ↓
///   project plan
///      ↓
///   task
///      ↓
///   WorkspaceSession
///      ↓
///   inferenza
///      ↓
///   proposta
///      ↓
///   review
///      ↓
///   validation
///      ↓
///   approval
///      ↓
///   apply
///
/// IMPORTANTE:
///
/// Questo Engine non deve diventare una seconda Chat Assistente.
///
/// Il Cantiere deve poter funzionare autonomamente anche quando la Chat
/// Assistente non è disponibile.
///
/// La CollaborationBus permette comunque ai due sistemi di collaborare
/// quando entrambi sono operativi.
///
/// Il WorkshopEngine non applica automaticamente modifiche al repository.
/// La protezione definitiva rimane affidata alla WorkspaceSession.
final class WorkshopEngine {
  WorkshopEngine({
    CollaborationBus? collaborationBus,
    WorkshopInferenceGateway? inferenceGateway,
    WorkshopProjectExecutor? projectExecutor,
  })  : _collaborationBus =
            collaborationBus ?? CollaborationBus.instance,
        _inferenceGateway = inferenceGateway,
        _projectExecutor = projectExecutor;

  final CollaborationBus _collaborationBus;
  final WorkshopInferenceGateway? _inferenceGateway;
  final WorkshopProjectExecutor? _projectExecutor;

  /// Richieste attive del Cantiere.
  final Map<String, WorkshopRequest> _requests =
      <String, WorkshopRequest>{};

  /// Stato corrente di ogni richiesta.
  final Map<String, WorkshopStage> _stages =
      <String, WorkshopStage>{};

  /// Piano di progetto associato alla richiesta.
  final Map<String, WorkshopProjectPlan> _plans =
      <String, WorkshopProjectPlan>{};

  /// Risultato più recente prodotto dal pipeline per richiesta.
  final Map<String, WorkshopResult> _lastResults =
      <String, WorkshopResult>{};

  final StreamController<WorkshopStageEvent>
      _stageController =
      StreamController<WorkshopStageEvent>.broadcast();

  Stream<WorkshopStageEvent> get stageStream =>
      _stageController.stream;

  List<WorkshopRequest> get requests =>
      List.unmodifiable(_requests.values);

  List<WorkshopProjectPlan> get plans =>
      List.unmodifiable(_plans.values);

  WorkshopStage? stageOf(String requestId) =>
      _stages[requestId];

  WorkshopProjectPlan? planOf(String requestId) =>
      _plans[requestId];

  WorkshopResult? lastResultOf(
    String requestId,
  ) =>
      _lastResults[requestId];

  bool get hasInferenceGateway =>
      _inferenceGateway != null;

  bool get hasProjectExecutor =>
      _projectExecutor != null;

  // ---------------------------------------------------------------------------
  // Main pipeline
  // ---------------------------------------------------------------------------

  /// Esegue una richiesta semplice del Cantiere.
  ///
  /// Questa API mantiene compatibilità con il precedente motore.
  ///
  /// Per produzioni vere, la UI utilizza normalmente:
  ///
  ///   createProjectPlan()
  ///        ↓
  ///   prepareNextProjectTask()
  ///        ↓
  ///   WorkspaceSession
  ///
  /// L'API execute() rimane comunque utile per il percorso conversazionale
  /// diretto e per la compatibilità con i chiamanti esistenti.
  Future<WorkshopResult> execute(
    WorkshopRequest request,
  ) async {
    _registerRequest(request);

    try {
      _setStage(
        request,
        WorkshopStage.requested,
      );

      _setStage(
        request,
        WorkshopStage.analysis,
      );

      final analysisResult = _analyse(request);

      _rememberResult(
        request.id,
        analysisResult,
      );

      if (!analysisResult.success) {
        _publishResult(
          request,
          analysisResult,
        );
        return analysisResult;
      }

      _setStage(
        request,
        WorkshopStage.planning,
      );

      final planResult = _plan(request);

      _rememberResult(
        request.id,
        planResult,
      );

      if (!planResult.success) {
        _publishResult(
          request,
          planResult,
        );
        return planResult;
      }

      _setStage(
        request,
        WorkshopStage.implementation,
      );

      final implementationResult =
          await _prepareImplementation(
        request,
      );

      _rememberResult(
        request.id,
        implementationResult,
      );

      if (!implementationResult.success) {
        _publishResult(
          request,
          implementationResult,
        );
        return implementationResult;
      }

      _setStage(
        request,
        WorkshopStage.review,
      );

      final reviewResult = _review(
        request,
        implementationResult,
      );

      _rememberResult(
        request.id,
        reviewResult,
      );

      if (!reviewResult.success) {
        _publishResult(
          request,
          reviewResult,
        );
        return reviewResult;
      }

      _setStage(
        request,
        WorkshopStage.validation,
      );

      final validationResult = await _validate(
        request,
        implementationResult,
      );

      _rememberResult(
        request.id,
        validationResult,
      );

      if (!validationResult.success) {
        _publishResult(
          request,
          validationResult,
        );
        return validationResult;
      }

      /*
       * IMPORTANTISSIMO:
       *
       * Una risposta LLM valida NON significa che il progetto sia già
       * completato.
       *
       * Finché non abbiamo:
       *
       *   proposta → workspace → review → validation → approval → apply
       *
       * non possiamo dichiarare il progetto realmente prodotto.
       *
       * Per questo il vecchio percorso che passava direttamente a
       * WorkshopStage.completed sarebbe stato prematuro.
       */

      final result = WorkshopResult(
        requestId: request.id,
        stage: WorkshopStage.validation,
        success: true,
        summary:
            'Workshop implementation is ready for workspace execution.',
        message:
            implementationResult.message,
        warnings: <String>[
          ...implementationResult.warnings,
          ...reviewResult.warnings,
          ...validationResult.warnings,
        ],
        nextActions: const <String>[
          'Prepare the project task workspace.',
          'Convert the implementation into workspace changes.',
          'Review the proposed changes.',
          'Validate the workspace.',
          'Require explicit approval before apply.',
        ],
      );

      _rememberResult(
        request.id,
        result,
      );

      _publishResult(
        request,
        result,
      );

      return result;
    } catch (error, stackTrace) {
      _setStage(
        request,
        WorkshopStage.blocked,
      );

      final result = WorkshopResult(
        requestId: request.id,
        stage: WorkshopStage.blocked,
        success: false,
        summary: 'Workshop task blocked.',
        message:
            'Workshop engine error: $error',
        errors: <String>[
          error.toString(),
          stackTrace.toString(),
        ],
      );

      _rememberResult(
        request.id,
        result,
      );

      _publishResult(
        request,
        result,
      );

      return result;
    }
  }

  // ---------------------------------------------------------------------------
  // Project lifecycle
  // ---------------------------------------------------------------------------

  /// Crea un piano di progetto per una richiesta.
  ///
  /// Questo è il vero punto di ingresso per la modalità Factory:
  ///
  ///   utente
  ///      ↓
  ///   WorkshopRequest
  ///      ↓
  ///   WorkshopProjectPlan
  ///
  /// Il metodo NON considera il progetto completato.
  ///
  /// Registra inoltre la richiesta nel motore e porta il Cantiere alla fase
  /// di planning, così Dashboard e stageStream vedono immediatamente lo
  /// stato corretto.
  WorkshopProjectPlan createProjectPlan(
    WorkshopRequest request, {
    WorkshopProjectDomain domain =
        WorkshopProjectDomain.software,
    List<WorkshopProjectPhase> phases =
        const <WorkshopProjectPhase>[],
    List<WorkshopProjectTask> tasks =
        const <WorkshopProjectTask>[],
    List<String> requirements =
        const <String>[],
    List<String> constraints =
        const <String>[],
    List<String> technologies =
        const <String>[],
    List<String> hardware =
        const <String>[],
    List<String> deliverables =
        const <String>[],
    List<String> validationCriteria =
        const <String>[],
  }) {
    _registerRequest(request);

    final plan = WorkshopProjectPlan(
      id: 'project:${request.id}',
      title: request.title,
      goal: request.instruction,
      domain: domain,
      status: WorkshopProjectStatus.planned,
      requirements: List.unmodifiable(
        requirements,
      ),
      constraints: List.unmodifiable(
        constraints,
      ),
      technologies: List.unmodifiable(
        technologies,
      ),
      hardware: List.unmodifiable(
        hardware,
      ),
      deliverables: List.unmodifiable(
        deliverables,
      ),
      validationCriteria: List.unmodifiable(
        validationCriteria,
      ),
      phases: phases,
      tasks: tasks,
    );

    _plans[request.id] = plan;

    _setStage(
      request,
      WorkshopStage.planning,
    );

    final result = WorkshopResult(
      requestId: request.id,
      stage: WorkshopStage.planning,
      success: true,
      summary: 'Workshop project plan created.',
      message:
          'The project plan is ready for task preparation.',
      nextActions: const <String>[
        'Prepare the next executable task.',
        'Open the task workspace.',
        'Start the implementation pipeline.',
      ],
    );

    _rememberResult(
      request.id,
      result,
    );

    _publishResult(
      request,
      result,
    );

    return plan;
  }

  /// Prepara il prossimo task del piano.
  ///
  /// Non applica modifiche al repository.
  ///
  /// Restituisce la WorkspaceSession che rappresenta il confine operativo
  /// del task.
  Future<WorkspaceSession?> prepareNextProjectTask(
    String requestId, {
    WorkshopBrief? brief,
  }) async {
    final executor = _requireProjectExecutor();

    final plan = _requirePlan(
      requestId,
    );

    final session = await executor.prepareNextTask(
      plan,
      brief: brief,
    );

    if (session == null) {
      _refreshProjectState(
        requestId,
      );

      return null;
    }

    final request = _requireRequest(
      requestId,
    );

    _setStage(
      request,
      WorkshopStage.implementation,
    );

    return session;
  }

  /// Prepara un task specifico del progetto.
  Future<WorkspaceSession> prepareProjectTask(
    String requestId,
    String taskId, {
    WorkshopBrief? brief,
  }) async {
    final executor = _requireProjectExecutor();

    final plan = _requirePlan(
      requestId,
    );

    final normalizedTaskId = taskId.trim();

    if (normalizedTaskId.isEmpty) {
      throw ArgumentError.value(
        taskId,
        'taskId',
        'Task id cannot be empty.',
      );
    }

    final session = await executor.prepareTask(
      plan,
      normalizedTaskId,
      brief: brief,
    );

    final request = _requireRequest(
      requestId,
    );

    _setStage(
      request,
      WorkshopStage.implementation,
    );

    return session;
  }

  /// Segna un task come completato soltanto quando la WorkspaceSession
  /// ha realmente raggiunto lo stato completed.
  ///
  /// Questo metodo non applica modifiche da solo.
  void completeProjectTask(
    String requestId,
    String taskId,
  ) {
    final executor = _requireProjectExecutor();

    final plan = _requirePlan(
      requestId,
    );

    executor.completeTask(
      plan,
      taskId,
    );

    final request = _requireRequest(
      requestId,
    );

    if (plan.status ==
        WorkshopProjectStatus.completed) {
      _setStage(
        request,
        WorkshopStage.completed,
      );

      final result = WorkshopResult(
        requestId: requestId,
        stage: WorkshopStage.completed,
        success: true,
        summary: 'Workshop project completed.',
        message:
            'All project tasks have completed successfully.',
        nextActions: const <String>[
          'Run the final build.',
          'Collect the generated artifact.',
          'Prepare the application for emission.',
        ],
      );

      _rememberResult(
        requestId,
        result,
      );

      _publishResult(
        request,
        result,
      );
    } else {
      _setStage(
        request,
        WorkshopStage.planning,
      );

      _refreshProjectState(
        requestId,
      );
    }
  }

  /// Restituisce il riepilogo del progetto corrente.
  WorkshopProjectSummary? projectSummary(
    String requestId,
  ) {
    final plan = _plans[requestId];

    if (plan == null) {
      return null;
    }

    final nextTask = plan.nextAvailableTask;

    return WorkshopProjectSummary(
      projectId: plan.id,
      title: plan.title,
      status: plan.status,
      progress: plan.progress,
      completedTasks: plan.completedTasks,
      totalTasks: plan.totalTasks,
      nextTaskId: nextTask?.id,
      nextTaskTitle: nextTask?.title,
    );
  }

  /// Annulla la produzione corrente.
  void cancel(
    String requestId,
  ) {
    final request = _requests[requestId];

    if (request == null) {
      return;
    }

    _projectExecutor?.cancelActiveSessions();

    _setStage(
      request,
      WorkshopStage.cancelled,
    );

    final result = WorkshopResult(
      requestId: request.id,
      stage: WorkshopStage.cancelled,
      success: false,
      summary: 'Workshop task cancelled.',
      message:
          'The construction request was cancelled.',
    );

    _rememberResult(
      request.id,
      result,
    );

    _publishResult(
      request,
      result,
    );
  }

  /// Dimentica una produzione dalla memoria volatile dell'Engine.
  ///
  /// IMPORTANTE:
  ///
  /// Questo metodo NON rappresenta la futura memoria persistente del
  /// progetto.
  ///
  /// Quando collegheremo ProjectMemoryRepository, "forget" dovrà rimuovere
  /// soltanto lo stato operativo della sessione, lasciando intatta la
  /// memoria riutilizzabile del progetto.
  void forget(
    String requestId,
  ) {
    _requests.remove(requestId);
    _stages.remove(requestId);
    _plans.remove(requestId);
    _lastResults.remove(requestId);
  }

  Future<void> dispose() async {
    await _stageController.close();
  }

  // ---------------------------------------------------------------------------
  // Basic pipeline
  // ---------------------------------------------------------------------------

  WorkshopResult _analyse(
    WorkshopRequest request,
  ) {
    final instruction =
        request.instruction.trim();

    if (instruction.isEmpty) {
      return WorkshopResult(
        requestId: request.id,
        stage: WorkshopStage.analysis,
        success: false,
        summary:
            'Empty Workshop instruction.',
        message:
            'The Workshop cannot analyse an empty instruction.',
        errors: const <String>[
          'instruction_empty',
        ],
      );
    }

    return WorkshopResult(
      requestId: request.id,
      stage: WorkshopStage.analysis,
      success: true,
      summary: 'Request analysed.',
      message:
          'The natural-language construction request is ready for planning.',
    );
  }

  WorkshopResult _plan(
    WorkshopRequest request,
  ) {
    return WorkshopResult(
      requestId: request.id,
      stage: WorkshopStage.planning,
      success: true,
      summary:
          'Construction plan prepared.',
      message:
          'Workshop operation ${request.operation.name} selected.',
      nextActions: const <String>[
        'Create or load the project plan.',
        'Select the next executable task.',
      ],
    );
  }

  /// Prepara la fase di implementazione.
  ///
  /// ATTENZIONE:
  ///
  /// Questo metodo genera ancora una risposta LLM, non modifica il workspace.
  ///
  /// Il prossimo anello dopo questo Engine sarà proprio il collegamento:
  ///
  ///   inference response
  ///        ↓
  ///   structured WorkshopChangeProposal
  ///        ↓
  ///   VirtualWorkspace
  ///
  /// Non bypassiamo questo confine.
  Future<WorkshopResult> _prepareImplementation(
    WorkshopRequest request,
  ) async {
    final gateway = _inferenceGateway;

    if (gateway == null) {
      return WorkshopResult(
        requestId: request.id,
        stage: WorkshopStage.implementation,
        success: false,
        summary:
            'Workshop inference is unavailable.',
        message:
            'The Workshop has no independent inference gateway attached.',
        errors: const <String>[
          'inference_gateway_not_attached',
        ],
        nextActions: const <String>[
          'Attach a working local or cloud inference provider.',
          'Retry the Workshop request.',
        ],
      );
    }

    final prompt =
        _buildWorkshopPrompt(request);

    final inferenceResult =
        await gateway.complete(
      prompt: prompt,
      systemPrompt:
          _workshopSystemPrompt,
      sessionId:
          'workshop:${request.id}',
      isOffline: true,
      modelId: null,
      modelPath: null,
    );

    if (inferenceResult.hasError) {
      return WorkshopResult(
        requestId: request.id,
        stage: WorkshopStage.implementation,
        success: false,
        summary:
            'Workshop inference failed.',
        message:
            inferenceResult.errorMessage ??
                'The Workshop inference pipeline returned an error.',
        errors: <String>[
          inferenceResult.errorMessage ??
              'workshop_inference_error',
        ],
      );
    }

    if (!inferenceResult.hasText) {
      return WorkshopResult(
        requestId: request.id,
        stage: WorkshopStage.implementation,
        success: false,
        summary:
            'Workshop produced no implementation response.',
        message:
            'The Workshop inference completed without generated content.',
        errors: const <String>[
          'empty_inference_response',
        ],
      );
    }

    return WorkshopResult(
      requestId: request.id,
      stage: WorkshopStage.implementation,
      success: true,
      summary:
          'Workshop implementation proposal generated.',
      message:
          inferenceResult.text.trim(),
      warnings:
          inferenceResult.runtimeNotice == null
              ? const <String>[]
              : <String>[
                  inferenceResult.runtimeNotice!,
                ],
      nextActions: const <String>[
        'Convert the response into a structured change proposal.',
        'Prepare workspace changes.',
        'Review the proposed changes.',
        'Validate before approval.',
      ],
    );
  }

  WorkshopResult _review(
    WorkshopRequest request,
    WorkshopResult implementationResult,
  ) {
    if (!implementationResult.success) {
      return WorkshopResult(
        requestId: request.id,
        stage: WorkshopStage.review,
        success: false,
        summary:
            'Review cannot continue.',
        message:
            'The implementation result is not valid for review.',
        errors: const <String>[
          'implementation_not_successful',
        ],
      );
    }

    return WorkshopResult(
      requestId: request.id,
      stage: WorkshopStage.review,
      success: true,
      summary:
          'Review boundary reached.',
      message:
          'The implementation proposal is ready for workspace review.',
      warnings: const <String>[
        'workspace_changes_not_yet_applied',
      ],
      nextActions: const <String>[
        'Create a WorkspaceChangeProposal.',
        'Generate a deterministic WorkspaceDiff.',
        'Show the proposed changes to the user.',
      ],
    );
  }

  Future<WorkshopResult> _validate(
    WorkshopRequest request,
    WorkshopResult implementationResult,
  ) async {
    if (!implementationResult.success) {
      return WorkshopResult(
        requestId: request.id,
        stage: WorkshopStage.validation,
        success: false,
        summary:
            'Validation cannot continue.',
        message:
            'The implementation result is not valid for validation.',
        errors: const <String>[
          'implementation_not_successful',
        ],
      );
    }

    return WorkshopResult(
      requestId: request.id,
      stage: WorkshopStage.validation,
      success: true,
      summary:
          'Validation boundary reached.',
      message:
          'The proposal is ready for the real workspace validation layer.',
      warnings: const <String>[
        'real_workspace_validation_not_yet_connected',
      ],
      nextActions: const <String>[
        'Validate the proposed workspace changes.',
        'Require explicit approval.',
        'Apply only after approval.',
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Prompt
  // ---------------------------------------------------------------------------

  static const String _workshopSystemPrompt = '''
You are the coding intelligence of the Workshop (Cantiere).

You are NOT the personal Assistant.

The Workshop is an independent construction environment.

Your responsibility is to help construct serious, maintainable projects.

Always:

- understand the existing project before changing it;
- respect the existing architecture;
- preserve working behaviour unless explicitly instructed otherwise;
- consider the whole project, not only one file;
- produce implementation plans for substantial requests;
- separate requirements, architecture, implementation and validation;
- prefer reversible and reviewable changes;
- never claim that a file was changed when it was only proposed;
- never claim that a build succeeded unless a real build succeeded;
- never claim that an application is ready until it has actually been built
  and validated.

For application-building requests, think in terms of:

requirements,
architecture,
project structure,
components,
dependencies,
implementation phases,
tests,
validation,
documentation,
artifacts,
and remaining work.

The Workshop can later support:

- software;
- embedded systems;
- electronics;
- robotics;
- CAD;
- manufacturing;
- 3D printing;
- mechanical systems;
- and other engineering domains.

Do not assume that every request is a simple code snippet.

When proposing code changes, keep the proposal reviewable and explicit.
Do not directly modify the real repository.
''';

  String _buildWorkshopPrompt(
    WorkshopRequest request,
  ) {
    final buffer =
        StringBuffer();

    buffer.writeln(
      'WORKSHOP REQUEST',
    );

    buffer.writeln(
      'Title: ${request.title}',
    );

    buffer.writeln(
      'Operation: ${request.operation.name}',
    );

    buffer.writeln(
      'Source: ${request.source.name}',
    );

    buffer.writeln();

    buffer.writeln(
      'INSTRUCTION:',
    );

    buffer.writeln(
      request.instruction,
    );

    if (request.projectPath != null &&
        request.projectPath!
            .trim()
            .isNotEmpty) {
      buffer.writeln();

      buffer.writeln(
        'PROJECT PATH:',
      );

      buffer.writeln(
        request.projectPath,
      );
    }

    if (request.targetFiles.isNotEmpty) {
      buffer.writeln();

      buffer.writeln(
        'TARGET FILES:',
      );

      for (final file
          in request.targetFiles) {
        buffer.writeln(
          '- $file',
        );
      }
    }

    if (request.constraints.isNotEmpty) {
      buffer.writeln();

      buffer.writeln(
        'CONSTRAINTS:',
      );

      for (final constraint
          in request.constraints) {
        buffer.writeln(
          '- $constraint',
        );
      }
    }

    if (request.context.isNotEmpty) {
      buffer.writeln();

      buffer.writeln(
        'WORKSHOP CONTEXT:',
      );

      for (final contextItem
          in request.context) {
        buffer.writeln(
          '- $contextItem',
        );
      }
    }

    buffer.writeln();

    buffer.writeln(
      'Return a coding-oriented response suitable for the next Workshop stage.',
    );

    buffer.writeln(
      'Do not claim that any file was modified.',
    );

    buffer.writeln(
      'Do not claim that a build or test succeeded unless it was actually executed.',
    );

    return buffer.toString();
  }

  // ---------------------------------------------------------------------------
  // Internal state
  // ---------------------------------------------------------------------------

  void _registerRequest(
    WorkshopRequest request,
  ) {
    _requests[request.id] = request;
  }

  WorkshopRequest _requireRequest(
    String requestId,
  ) {
    final request =
        _requests[requestId];

    if (request == null) {
      throw StateError(
        'No WorkshopRequest exists for request "$requestId".',
      );
    }

    return request;
  }

  WorkshopProjectPlan _requirePlan(
    String requestId,
  ) {
    final plan =
        _plans[requestId];

    if (plan == null) {
      throw StateError(
        'No WorkshopProjectPlan exists for request "$requestId".',
      );
    }

    return plan;
  }

  WorkshopProjectExecutor
      _requireProjectExecutor() {
    final executor =
        _projectExecutor;

    if (executor == null) {
      throw StateError(
        'WorkshopProjectExecutor is not attached to WorkshopEngine.',
      );
    }

    return executor;
  }

  void _rememberResult(
    String requestId,
    WorkshopResult result,
  ) {
    _lastResults[requestId] =
        result;
  }

  void _refreshProjectState(
    String requestId,
  ) {
    final request =
        _requests[requestId];

    if (request == null) {
      return;
    }

    final plan =
        _plans[requestId];

    if (plan == null) {
      return;
    }

    if (plan.status ==
        WorkshopProjectStatus.completed) {
      _setStage(
        request,
        WorkshopStage.completed,
      );
      return;
    }

    if (plan.status ==
        WorkshopProjectStatus.blocked) {
      _setStage(
        request,
        WorkshopStage.blocked,
      );
      return;
    }

    _setStage(
      request,
      WorkshopStage.planning,
    );
  }

  // ---------------------------------------------------------------------------
  // Collaboration
  // ---------------------------------------------------------------------------

  void _publishResult(
    WorkshopRequest request,
    WorkshopResult result,
  ) {
    final messageType =
        result.success
            ? CollaborationMessageType.result
            : CollaborationMessageType.error;

    _collaborationBus.send(
      source:
          CollaborationParticipant.workshop,
      target:
          CollaborationParticipant.orchestrator,
      type: messageType,
      content: result.message,
      sessionId: request.id,
      projectId: request.projectPath,
      metadata: <String, String>{
        'stage':
            result.stage.name,
        'success':
            result.success.toString(),
      },
    );
  }

  void _setStage(
    WorkshopRequest request,
    WorkshopStage stage,
  ) {
    _stages[request.id] =
        stage;

    final event =
        WorkshopStageEvent(
      requestId: request.id,
      stage: stage,
      timestamp:
          DateTime.now(),
    );

    if (!_stageController
        .isClosed) {
      _stageController.add(
        event,
      );
    }
  }
}

/// Evento di avanzamento del Cantiere.
final class WorkshopStageEvent {
  const WorkshopStageEvent({
    required this.requestId,
    required this.stage,
    required this.timestamp,
  });

  final String requestId;
  final WorkshopStage stage;
  final DateTime timestamp;
}

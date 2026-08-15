import 'dart:async';

import '../collaboration/collaboration_bus.dart';
import '../workspace/workspace_session.dart';
import 'workshop_contract.dart';
import 'workshop_inference_gateway.dart';
import 'workshop_project_executor.dart';
import 'workshop_project_plan.dart';

/// Motore centrale del Cantiere.
///
/// Il WorkshopEngine coordina il ciclo di vita di una richiesta e, quando
/// disponibile un [WorkshopProjectExecutor], può trasformare la richiesta
/// in un vero progetto composto da fasi e task.
///
/// Pipeline:
///
///   richiesta naturale
///        ↓
///   analisi
///        ↓
///   project plan
///        ↓
///   task eseguibile
///        ↓
///   WorkspaceSession
///        ↓
///   inferenza
///        ↓
///   review
///        ↓
///   validation
///        ↓
///   approval
///        ↓
///   apply
///
/// Il motore NON applica automaticamente modifiche al repository.
///
/// La Chat Assistente resta indipendente:
/// il Cantiere può essere utilizzato direttamente dall'utente senza
/// richiedere la presenza dell'A-team.
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

  final Map<String, WorkshopRequest> _requests =
      <String, WorkshopRequest>{};

  final Map<String, WorkshopStage> _stages =
      <String, WorkshopStage>{};

  final Map<String, WorkshopProjectPlan> _plans =
      <String, WorkshopProjectPlan>{};

  final StreamController<WorkshopStageEvent> _stageController =
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

  bool get hasInferenceGateway =>
      _inferenceGateway != null;

  bool get hasProjectExecutor =>
      _projectExecutor != null;

  /// Esegue una richiesta semplice del Cantiere.
  ///
  /// Questa API mantiene compatibilità con il precedente motore.
  Future<WorkshopResult> execute(
    WorkshopRequest request,
  ) async {
    _requests[request.id] = request;

    try {
      _setStage(request, WorkshopStage.requested);

      _setStage(request, WorkshopStage.analysis);

      final analysisResult = _analyse(request);

      if (!analysisResult.success) {
        _publishResult(request, analysisResult);
        return analysisResult;
      }

      _setStage(request, WorkshopStage.planning);

      final planResult = _plan(request);

      if (!planResult.success) {
        _publishResult(request, planResult);
        return planResult;
      }

      _setStage(request, WorkshopStage.implementation);

      final implementationResult =
          await _prepareImplementation(request);

      if (!implementationResult.success) {
        _publishResult(request, implementationResult);
        return implementationResult;
      }

      _setStage(request, WorkshopStage.review);

      final reviewResult = _review(
        request,
        implementationResult,
      );

      if (!reviewResult.success) {
        _publishResult(request, reviewResult);
        return reviewResult;
      }

      _setStage(request, WorkshopStage.validation);

      final validationResult = await _validate(
        request,
        implementationResult,
      );

      if (!validationResult.success) {
        _publishResult(request, validationResult);
        return validationResult;
      }

      _setStage(request, WorkshopStage.completed);

      final result = WorkshopResult(
        requestId: request.id,
        stage: WorkshopStage.completed,
        success: true,
        summary: 'Workshop pipeline completed.',
        message: implementationResult.message,
        warnings: <String>[
          ...implementationResult.warnings,
          ...reviewResult.warnings,
          ...validationResult.warnings,
        ],
        nextActions: const <String>[
          'Present the result to the user.',
          'Review workspace changes before applying them.',
          'Optionally request an A-team review.',
        ],
      );

      _publishResult(request, result);

      return result;
    } catch (error, stackTrace) {
      _setStage(request, WorkshopStage.blocked);

      final result = WorkshopResult(
        requestId: request.id,
        stage: WorkshopStage.blocked,
        success: false,
        summary: 'Workshop task blocked.',
        message: 'Workshop engine error: $error',
        errors: <String>[
          error.toString(),
          stackTrace.toString(),
        ],
      );

      _publishResult(request, result);

      return result;
    }
  }

  /// Crea un piano di progetto per una richiesta.
  ///
  /// Questo è il percorso utilizzato quando l'utente chiede qualcosa
  /// di sostanziale, ad esempio:
  ///
  ///   "Fammi questa applicazione."
  ///
  /// Il piano non viene considerato automaticamente completato.
  WorkshopProjectPlan createProjectPlan(
    WorkshopRequest request, {
    WorkshopProjectDomain domain =
        WorkshopProjectDomain.software,
    List<WorkshopProjectPhase> phases =
        const <WorkshopProjectPhase>[],
    List<WorkshopProjectTask> tasks =
        const <WorkshopProjectTask>[],
    List<String> requirements = const <String>[],
    List<String> constraints = const <String>[],
    List<String> technologies = const <String>[],
    List<String> hardware = const <String>[],
    List<String> deliverables = const <String>[],
    List<String> validationCriteria = const <String>[],
  }) {
    final plan = WorkshopProjectPlan(
      id: 'project:${request.id}',
      title: request.title,
      goal: request.instruction,
      domain: domain,
      status: WorkshopProjectStatus.planned,
      requirements: requirements,
      constraints: constraints,
      technologies: technologies,
      hardware: hardware,
      deliverables: deliverables,
      validationCriteria: validationCriteria,
      phases: phases,
      tasks: tasks,
    );

    _plans[request.id] = plan;

    return plan;
  }

  /// Prepara il prossimo task del piano.
  ///
  /// Non applica modifiche.
  ///
  /// Restituisce la WorkspaceSession pronta per il successivo ciclo
  /// di implementazione.
  Future<WorkspaceSession?> prepareNextProjectTask(
    String requestId, {
    WorkshopBrief? brief,
  }) async {
    final executor = _projectExecutor;

    if (executor == null) {
      throw StateError(
        'WorkshopProjectExecutor is not attached to WorkshopEngine.',
      );
    }

    final plan = _plans[requestId];

    if (plan == null) {
      throw StateError(
        'No WorkshopProjectPlan exists for request "$requestId".',
      );
    }

    final session = await executor.prepareNextTask(
      plan,
      brief: brief,
    );

    if (session == null) {
      return null;
    }

    _setStage(
      _requests[requestId] ??
          WorkshopRequest(
            id: requestId,
            title: plan.title,
            instruction: plan.goal,
          ),
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
    final executor = _projectExecutor;

    if (executor == null) {
      throw StateError(
        'WorkshopProjectExecutor is not attached to WorkshopEngine.',
      );
    }

    final plan = _plans[requestId];

    if (plan == null) {
      throw StateError(
        'No WorkshopProjectPlan exists for request "$requestId".',
      );
    }

    final session = await executor.prepareTask(
      plan,
      taskId,
      brief: brief,
    );

    _setStage(
      _requests[requestId] ??
          WorkshopRequest(
            id: requestId,
            title: plan.title,
            instruction: plan.goal,
          ),
      WorkshopStage.implementation,
    );

    return session;
  }

  /// Segna il task come completato solo dopo che la WorkspaceSession
  /// ha realmente raggiunto lo stato completed.
  void completeProjectTask(
    String requestId,
    String taskId,
  ) {
    final executor = _projectExecutor;

    if (executor == null) {
      throw StateError(
        'WorkshopProjectExecutor is not attached to WorkshopEngine.',
      );
    }

    final plan = _plans[requestId];

    if (plan == null) {
      throw StateError(
        'No WorkshopProjectPlan exists for request "$requestId".',
      );
    }

    executor.completeTask(plan, taskId);

    final request = _requests[requestId];

    if (request != null) {
      if (plan.status == WorkshopProjectStatus.completed) {
        _setStage(request, WorkshopStage.completed);
      } else {
        _setStage(request, WorkshopStage.planning);
      }
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

  void cancel(String requestId) {
    final request = _requests[requestId];

    if (request == null) {
      return;
    }

    _projectExecutor?.cancelActiveSessions();

    _setStage(request, WorkshopStage.cancelled);

    final result = WorkshopResult(
      requestId: request.id,
      stage: WorkshopStage.cancelled,
      success: false,
      summary: 'Workshop task cancelled.',
      message: 'The construction request was cancelled.',
    );

    _publishResult(request, result);
  }

  void forget(String requestId) {
    _requests.remove(requestId);
    _stages.remove(requestId);
    _plans.remove(requestId);
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
    final instruction = request.instruction.trim();

    if (instruction.isEmpty) {
      return WorkshopResult(
        requestId: request.id,
        stage: WorkshopStage.analysis,
        success: false,
        summary: 'Empty Workshop instruction.',
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
      summary: 'Construction plan prepared.',
      message:
          'Workshop operation ${request.operation.name} selected.',
      nextActions: const <String>[
        'Create or load the project plan.',
        'Select the next executable task.',
      ],
    );
  }

  Future<WorkshopResult> _prepareImplementation(
    WorkshopRequest request,
  ) async {
    final gateway = _inferenceGateway;

    if (gateway == null) {
      return WorkshopResult(
        requestId: request.id,
        stage: WorkshopStage.implementation,
        success: true,
        summary: 'Implementation stage prepared.',
        message:
            'The Workshop is ready to pass the request to its coding pipeline.',
        warnings: const <String>[
          'inference_gateway_not_attached',
        ],
      );
    }

    final prompt = _buildWorkshopPrompt(request);

    final inferenceResult = await gateway.complete(
      prompt: prompt,
      systemPrompt: _workshopSystemPrompt,
      sessionId: 'workshop:${request.id}',
      isOffline: true,
      modelId: null,
      modelPath: null,
    );

    if (inferenceResult.hasError) {
      return WorkshopResult(
        requestId: request.id,
        stage: WorkshopStage.implementation,
        success: false,
        summary: 'Workshop inference failed.',
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
      summary: 'Workshop implementation generated.',
      message: inferenceResult.text.trim(),
      warnings: inferenceResult.runtimeNotice == null
          ? const <String>[]
          : <String>[
              inferenceResult.runtimeNotice!,
            ],
      nextActions: const <String>[
        'Review the generated implementation.',
        'Prepare workspace changes.',
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
        summary: 'Review cannot continue.',
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
      summary: 'Review stage passed.',
      message:
          'The result is ready for workspace review.',
      warnings: const <String>[
        'workspace_changes_not_yet_applied',
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
        summary: 'Validation cannot continue.',
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
      summary: 'Validation boundary passed.',
      message:
          'The result is ready for the real project validation layer.',
      warnings: const <String>[
        'real_build_and_test_validation_not_connected',
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Prompt
  // ---------------------------------------------------------------------------

  static const String _workshopSystemPrompt = '''
You are the coding intelligence of the Workshop (Cantiere).

You are not the personal Assistant.

Your responsibility is to help construct serious, maintainable projects.

Always:
- understand the existing project before changing it;
- respect the existing architecture;
- preserve working behaviour unless explicitly instructed otherwise;
- consider the whole project, not only one file;
- produce implementation plans for substantial requests;
- separate requirements, architecture, implementation and validation;
- prefer reversible and reviewable changes;
- never claim that a file was changed when it was only proposed.

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
and remaining work.

The Workshop can later support software, embedded systems, electronics,
robotics, CAD and other engineering domains. Do not assume that every
request is a simple code snippet.
''';

  String _buildWorkshopPrompt(
    WorkshopRequest request,
  ) {
    final buffer = StringBuffer();

    buffer.writeln('WORKSHOP REQUEST');
    buffer.writeln('Title: ${request.title}');
    buffer.writeln('Operation: ${request.operation.name}');
    buffer.writeln('Source: ${request.source.name}');
    buffer.writeln();
    buffer.writeln('INSTRUCTION:');
    buffer.writeln(request.instruction);

    if (request.projectPath != null &&
        request.projectPath!.trim().isNotEmpty) {
      buffer.writeln();
      buffer.writeln('PROJECT PATH:');
      buffer.writeln(request.projectPath);
    }

    if (request.targetFiles.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('TARGET FILES:');

      for (final file in request.targetFiles) {
        buffer.writeln('- $file');
      }
    }

    if (request.constraints.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('CONSTRAINTS:');

      for (final constraint in request.constraints) {
        buffer.writeln('- $constraint');
      }
    }

    if (request.context.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('WORKSHOP CONTEXT:');

      for (final contextItem in request.context) {
        buffer.writeln('- $contextItem');
      }
    }

    buffer.writeln();
    buffer.writeln(
      'Return a coding-oriented response suitable for the next Workshop stage.',
    );

    return buffer.toString();
  }

  // ---------------------------------------------------------------------------
  // Collaboration
  // ---------------------------------------------------------------------------

  void _publishResult(
    WorkshopRequest request,
    WorkshopResult result,
  ) {
    final messageType = result.success
        ? CollaborationMessageType.result
        : CollaborationMessageType.error;

    _collaborationBus.send(
      source: CollaborationParticipant.workshop,
      target: CollaborationParticipant.orchestrator,
      type: messageType,
      content: result.message,
      sessionId: request.id,
      projectId: request.projectPath,
      metadata: <String, String>{
        'stage': result.stage.name,
        'success': result.success.toString(),
      },
    );
  }

  void _setStage(
    WorkshopRequest request,
    WorkshopStage stage,
  ) {
    _stages[request.id] = stage;

    final event = WorkshopStageEvent(
      requestId: request.id,
      stage: stage,
      timestamp: DateTime.now(),
    );

    if (!_stageController.isClosed) {
      _stageController.add(event);
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

/// Riepilogo leggero di un progetto Workshop.
final class WorkshopProjectSummary {
  const WorkshopProjectSummary({
    required this.projectId,
    required this.title,
    required this.status,
    required this.progress,
    required this.completedTasks,
    required this.totalTasks,
    this.nextTaskId,
    this.nextTaskTitle,
  });

  final String projectId;
  final String title;
  final WorkshopProjectStatus status;
  final double progress;
  final int completedTasks;
  final int totalTasks;
  final String? nextTaskId;
  final String? nextTaskTitle;

  bool get isComplete =>
      status == WorkshopProjectStatus.completed;

  bool get hasNextTask =>
      nextTaskId != null;
}

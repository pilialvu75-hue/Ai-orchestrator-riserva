import 'dart:async';

import '../collaboration/collaboration_bus.dart';
import 'workshop_contract.dart';
import 'workshop_inference_gateway.dart';

/// Motore centrale del Cantiere.
///
/// Il WorkshopEngine coordina il ciclo di vita di una richiesta di
/// programmazione senza essere accoppiato:
///
/// - alla Chat Assistente;
/// - a un particolare LLM;
/// - a GitHub;
/// - alla UI;
/// - a una specifica implementazione del workspace.
///
/// L'inferenza passa esclusivamente attraverso
/// [WorkshopInferenceGateway].
///
/// Questo mantiene il Cantiere indipendente dalla Chat Assistente:
///
///   richiesta naturale
///        ↓
///   analisi
///        ↓
///   pianificazione
///        ↓
///   WorkshopInferenceGateway
///        ↓
///   modello locale/cloud
///        ↓
///   review
///        ↓
///   validazione
///        ↓
///   risultato
///
/// IMPORTANTE:
/// questo livello NON modifica autonomamente file reali.
/// Le operazioni mutanti saranno introdotte attraverso il workspace
/// e i relativi guardrail.
final class WorkshopEngine {
  WorkshopEngine({
    CollaborationBus? collaborationBus,
    WorkshopInferenceGateway? inferenceGateway,
  })  : _collaborationBus =
            collaborationBus ?? CollaborationBus.instance,
        _inferenceGateway = inferenceGateway;

  final CollaborationBus _collaborationBus;
  final WorkshopInferenceGateway? _inferenceGateway;

  final Map<String, WorkshopRequest> _requests =
      <String, WorkshopRequest>{};

  final Map<String, WorkshopStage> _stages =
      <String, WorkshopStage>{};

  final StreamController<WorkshopStageEvent> _stageController =
      StreamController<WorkshopStageEvent>.broadcast();

  /// Stream degli avanzamenti del Cantiere.
  Stream<WorkshopStageEvent> get stageStream =>
      _stageController.stream;

  /// Snapshot delle richieste attualmente conosciute.
  List<WorkshopRequest> get requests =>
      List.unmodifiable(_requests.values);

  /// Restituisce lo stato corrente di una richiesta.
  WorkshopStage? stageOf(String requestId) =>
      _stages[requestId];

  /// Indica se il Cantiere dispone di un gateway di inferenza.
  bool get hasInferenceGateway =>
      _inferenceGateway != null;

  /// Avvia una nuova lavorazione.
  ///
  /// La richiesta può provenire direttamente dall'utente oppure
  /// dall'Assistente/A-team.
  Future<WorkshopResult> execute(
    WorkshopRequest request,
  ) async {
    _requests[request.id] = request;

    try {
      _setStage(request, WorkshopStage.requested);

      _setStage(request, WorkshopStage.analysis);

      final analysisResult = _analyse(request);

      if (!analysisResult.success) {
        return analysisResult;
      }

      _setStage(request, WorkshopStage.planning);

      final planResult = _plan(request);

      if (!planResult.success) {
        return planResult;
      }

      _setStage(request, WorkshopStage.implementation);

      final implementationResult =
          await _prepareImplementation(request);

      if (!implementationResult.success) {
        return implementationResult;
      }

      _setStage(request, WorkshopStage.review);

      final reviewResult = _review(request);

      if (!reviewResult.success) {
        return reviewResult;
      }

      _setStage(request, WorkshopStage.validation);

      final validationResult = await _validate(request);

      if (!validationResult.success) {
        return validationResult;
      }

      _setStage(request, WorkshopStage.completed);

      final result = WorkshopResult(
        requestId: request.id,
        stage: WorkshopStage.completed,
        success: true,
        summary: 'Workshop task completed.',
        message:
            'The Workshop completed the requested construction pipeline.',
        nextActions: const <String>[
          'Present the result to the user.',
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

  /// Cancella una lavorazione ancora in corso.
  ///
  /// Non modifica file e non annulla automaticamente eventuali
  /// operazioni già autorizzate da livelli inferiori.
  void cancel(String requestId) {
    final request = _requests[requestId];

    if (request == null) {
      return;
    }

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

  /// Rimuove una richiesta dalla memoria volatile del motore.
  ///
  /// Non elimina file, commit, repository o memoria persistente.
  void forget(String requestId) {
    _requests.remove(requestId);
    _stages.remove(requestId);
  }

  /// Chiude lo stream del motore.
  Future<void> dispose() async {
    await _stageController.close();
  }

  // ---------------------------------------------------------------------------
  // Pipeline stages
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
    final operation = request.operation;

    return WorkshopResult(
      requestId: request.id,
      stage: WorkshopStage.planning,
      success: true,
      summary: 'Construction plan prepared.',
      message:
          'Workshop operation ${operation.name} selected.',
      nextActions: const <String>[
        'Prepare the workspace context.',
        'Generate or refine the implementation.',
      ],
    );
  }

  /// Passa finalmente la richiesta reale al modello del Cantiere.
  ///
  /// Questa è la prima connessione effettiva tra il Workshop e la
  /// pipeline di inferenza.
  ///
  /// Nessun passaggio dalla Chat Assistente viene effettuato.
  Future<WorkshopResult> _prepareImplementation(
    WorkshopRequest request,
  ) async {
    final gateway = _inferenceGateway;

    /*
     * Compatibilità conservativa:
     *
     * se un'istanza del WorkshopEngine non dispone ancora del gateway,
     * manteniamo il comportamento precedente invece di introdurre
     * un crash o una dipendenza obbligatoria.
     */
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
        summary: 'Workshop produced no implementation response.',
        message:
            'The Workshop inference completed without generated content.',
        errors: const <String>[
          'empty_inference_response',
        ],
      );
    }

    final generatedText = inferenceResult.text.trim();

    return WorkshopResult(
      requestId: request.id,
      stage: WorkshopStage.implementation,
      success: true,
      summary: 'Workshop implementation generated.',
      message: generatedText,
      warnings: inferenceResult.runtimeNotice == null
          ? const <String>[]
          : <String>[
              inferenceResult.runtimeNotice!,
            ],
      nextActions: const <String>[
        'Review the generated implementation.',
        'Apply only explicitly approved file changes.',
        'Run validation before completion.',
      ],
    );
  }

  WorkshopResult _review(
    WorkshopRequest request,
  ) {
    return WorkshopResult(
      requestId: request.id,
      stage: WorkshopStage.review,
      success: true,
      summary: 'Review stage passed.',
      message:
          'No destructive operation was performed by the Workshop engine.',
    );
  }

  Future<WorkshopResult> _validate(
    WorkshopRequest request,
  ) async {
    return WorkshopResult(
      requestId: request.id,
      stage: WorkshopStage.validation,
      success: true,
      summary: 'Validation stage prepared.',
      message:
          'The validation boundary is ready for the real project validators.',
    );
  }

  // ---------------------------------------------------------------------------
  // Workshop prompt boundary
  // ---------------------------------------------------------------------------

  static const String _workshopSystemPrompt = '''
You are the coding intelligence of the Workshop (Cantiere).

Your primary responsibility is software engineering.

Focus on:
- understanding existing code before changing it;
- architecture;
- implementation;
- debugging;
- refactoring;
- tests;
- build stability;
- performance;
- maintainability;
- platform constraints.

The Workshop is independent from the personal Assistant.

Do not assume access to the Assistant conversation.
Do not invent repository contents that were not supplied.
Do not propose destructive changes without explicit justification.
Prefer small, reviewable and reversible changes.
Preserve working functionality unless the task explicitly requires otherwise.

When the request concerns an existing project, analyse first and clearly
separate:
1. what is known;
2. what must be changed;
3. what should be validated.
''';

  String _buildWorkshopPrompt(
    WorkshopRequest request,
  ) {
    final buffer = StringBuffer();

    buffer.writeln('WORKSHOP REQUEST');
    buffer.writeln('Title: ${request.title}');
    buffer.writeln('Operation: ${request.operation.name}');
    buffer.writeln('Instruction:');
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

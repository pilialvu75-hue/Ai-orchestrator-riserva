import 'dart:io';

import 'package:ai_orchestrator/core/orchestrator/execution_engine.dart';
import 'package:ai_orchestrator/core/orchestrator/intent_analyzer.dart';
import 'package:ai_orchestrator/core/orchestrator/task_type.dart';
import 'package:ai_orchestrator/core/planner/planner_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_constants.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:flutter/foundation.dart';

/// Central routing layer for all AI calls.
///
/// Classifica l'intent utente con [IntentAnalyzer], delega i comandi
/// device a [ExecutionEngine], instrada planning/coding a [PlannerService],
/// le ricerche web a [_handleWebSearchStream] (controlla connettività reale),
/// e le query chat a [InferenceService].
class Orchestrator {
  Orchestrator({
    required IntentAnalyzer intentAnalyzer,
    required ExecutionEngine executor,
    required InferenceService inferenceService,
    PlannerService? plannerService,
  })  : _analyzer = intentAnalyzer,
        _executor = executor,
        _inferenceService = inferenceService,
        _plannerService = plannerService;

  final IntentAnalyzer _analyzer;
  final ExecutionEngine _executor;
  final InferenceService _inferenceService;
  final PlannerService? _plannerService;

  Future<InferenceResponse> handle(
    String input, {
    String? systemPrompt,
    bool isOffline = false,
  }) async {
    final type = _analyzer.analyze(input);

    switch (type) {
      case TaskType.command:
        return _executeCommand(input);
      case TaskType.plan:
      case TaskType.coding:
        return _executePlan(input, isOffline: isOffline);
      case TaskType.webSearch:
        // handle() sincrono — risposta informativa diretta.
        // La connettività viene verificata solo in handleStream.
        return InferenceResponse.finalChunk(
          text: 'Verifica la connessione e usa la modalità Cloud '
              'o Hybrid nelle impostazioni per cercare online.',
          model: InferenceConstants.localModelName,
          tokensGenerated: 0,
        );
      case TaskType.chat:
      case TaskType.system:
        return _inferenceService.infer(
          InferenceRequest(
            sessionId: 'default',
            prompt: input,
            systemPrompt: systemPrompt,
            isOffline: isOffline,
          ),
        );
    }
  }

  TokenStream handleStream(
    String input, {
    required String sessionId,
    List<ChatTurn> context = const [],
    String? systemPrompt,
    bool isOffline = false,
    int? maxTokens,
    double? temperature,
  }) {
    _logForensic(
      '[ORCHESTRATOR_SEND] session=$sessionId'
      ' stage=orchestrator.handleStream'
      ' prompt_chars=${input.length}'
      ' context_turns=${context.length}',
    );

    final type = _analyzer.analyze(input);

    _logForensic(
      '[ORCHESTRATOR_ROUTE] session=$sessionId'
      ' task_type=${type.name}'
      ' will_stream_inference=${type == TaskType.chat || type == TaskType.system}',
    );

    final contextSnapshot = List<ChatTurn>.unmodifiable(context);

    if (type == TaskType.command) {
      _logForensic(
        '[PRE_STREAM_BYPASS] session=$sessionId'
        ' boundary=orchestrator.intent_route'
        ' reason=task_type_command target=_executeCommand',
      );
      return Stream.fromFuture(_executeCommand(input));
    }

    if (type == TaskType.plan || type == TaskType.coding) {
      _logForensic(
        '[PRE_STREAM_BYPASS] session=$sessionId'
        ' boundary=orchestrator.intent_route'
        ' reason=task_type_${type.name} target=_executePlan',
      );
      return Stream.fromFuture(
        _executePlan(input, isOffline: isOffline),
      );
    }

    if (type == TaskType.webSearch) {
      _logForensic(
        '[PRE_STREAM_BYPASS] session=$sessionId'
        ' boundary=orchestrator.intent_route'
        ' reason=task_type_webSearch',
      );
      return _handleWebSearchStream(
        input: input,
        sessionId: sessionId,
        context: contextSnapshot,
        systemPrompt: systemPrompt,
        isOffline: isOffline,
        maxTokens: maxTokens,
        temperature: temperature,
      );
    }

    _logForensic(
      '[PRE_STREAM_FORWARD] session=$sessionId'
      ' boundary=orchestrator.intent_route'
      ' target=inference_service.stream task_type=${type.name}',
    );

    return _inferenceService.stream(
      InferenceRequest(
        sessionId: sessionId,
        prompt: input,
        systemPrompt: systemPrompt,
        context: contextSnapshot,
        isOffline: isOffline,
        maxTokens: maxTokens ?? InferenceRequest.defaultMaxTokens,
        temperature: temperature ?? InferenceRequest.defaultTemperature,
      ),
    );
  }

  /// Gestisce le richieste di ricerca web.
  ///
  /// Controlla la connettività reale con [InternetAddress.lookup] senza
  /// dipendenze esterne. Se c'è rete, passa la richiesta al modello locale
  /// che risponde con le sue conoscenze. Se non c'è rete, emette un
  /// messaggio informativo immediato senza coinvolgere l'LLM.
  TokenStream _handleWebSearchStream({
    required String input,
    required String sessionId,
    required List<ChatTurn> context,
    required String? systemPrompt,
    required bool isOffline,
    required int? maxTokens,
    required double? temperature,
  }) async* {
    bool hasInternet = false;
    if (!isOffline) {
      try {
        final result = await InternetAddress.lookup('google.com')
            .timeout(const Duration(seconds: 3));
        hasInternet =
            result.isNotEmpty && result.first.rawAddress.isNotEmpty;
      } catch (_) {
        hasInternet = false;
      }
    }

    _logForensic(
      '[WEB_SEARCH] session=$sessionId'
      ' hasInternet=$hasInternet isOffline=$isOffline',
    );

    if (!hasInternet) {
      yield InferenceResponse.finalChunk(
        text: 'Non ho accesso a internet in questo momento. '
            'Verifica la connessione o passa alla modalità Cloud '
            'nelle impostazioni per cercare online.',
        model: InferenceConstants.localModelName,
        tokensGenerated: 0,
      );
      return;
    }

    // Connessione disponibile: il modello risponde con le sue conoscenze.
    // L'accesso diretto a internet in LOCAL mode è pianificato per una
    // versione futura con integrazione API di ricerca (es. DuckDuckGo).
    yield* _inferenceService.stream(
      InferenceRequest(
        sessionId: sessionId,
        prompt: input,
        systemPrompt: systemPrompt,
        context: context,
        isOffline: false,
        maxTokens: maxTokens ?? InferenceRequest.defaultMaxTokens,
        temperature: temperature ?? InferenceRequest.defaultTemperature,
      ),
    );
  }

  static void _logForensic(String message) {
    debugPrint(message);
    RuntimeEventLog.instance.emit(message);
  }

  Future<InferenceResponse> _executeCommand(String input) async {
    final commandOutput = await _executor.execute(input);
    return InferenceResponse.finalChunk(
      text: commandOutput,
      model: InferenceConstants.localModelName,
      tokensGenerated: 0,
    );
  }

  /// Decompone [input] in un [Plan] ed esegue ogni step.
  ///
  /// Fallback a inference normale quando [PlannerService] non è configurato.
  Future<InferenceResponse> _executePlan(
    String input, {
    bool isOffline = false,
  }) async {
    final planner = _plannerService;
    if (planner == null) {
      return _inferenceService.infer(
        InferenceRequest(
          sessionId: 'default',
          prompt: input,
          isOffline: isOffline,
        ),
      );
    }

    final plan = await planner.decompose(input, isOffline: isOffline);

    return InferenceResponse.finalChunk(
      text: plan.toDisplayString(),
      model: InferenceConstants.localModelName,
      tokensGenerated: plan.steps.length,
    );
  }
}

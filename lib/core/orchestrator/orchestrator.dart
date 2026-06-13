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
/// le ricerche web a una risposta informativa (LOCAL) o al provider cloud
/// (CLOUD/HYBRID), e le query chat a [InferenceService].
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
        // In handle() sincrono restituiamo risposta informativa diretta.
        return InferenceResponse.finalChunk(
          text: 'Non ho accesso a internet in modalità locale. '
              'Passa alla modalità Cloud o Hybrid nelle impostazioni '
              'per cercare online.',
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
      ' will_stream_inference=${type == TaskType.chat || type == TaskType.system || type == TaskType.webSearch}',
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

    // Ricerca web in modalità locale → risposta informativa via LLM
    // con system prompt dedicato e token ridotti.
    // In modalità cloud/hybrid il provider ha già accesso a internet
    // e gestisce la ricerca nativamente.
    if (type == TaskType.webSearch) {
      _logForensic(
        '[PRE_STREAM_BYPASS] session=$sessionId'
        ' boundary=orchestrator.intent_route'
        ' reason=task_type_webSearch isOffline=$isOffline',
      );
      return _inferenceService.stream(
        InferenceRequest(
          sessionId: sessionId,
          prompt: input,
          systemPrompt:
              'You are AI Orchestrator running in LOCAL mode without internet. '
              'The user is asking to search the web. '
              'Reply ONLY with this sentence, translated to match the user language: '
              '"Non ho accesso a internet in modalità locale. '
              'Passa alla modalità Cloud o Hybrid nelle impostazioni per cercare online." '
              'Do not add anything else.',
          context: const [],
          isOffline: isOffline,
          maxTokens: 64,
          temperature: 0.1,
        ),
      );
    }

    // Chat / system → inference normale con parametri adattivi.
    // InferenceService._buildLocalRequest sovrascriverà maxTokens e
    // temperature con valori calibrati sul modello effettivo.
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

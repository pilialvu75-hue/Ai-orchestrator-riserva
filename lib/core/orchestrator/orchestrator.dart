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
/// Step 3 – execution engine: classifica l'intent utente con [IntentAnalyzer],
/// delega i comandi device a [ExecutionEngine] (platform-specific), instrada
/// planning/coding attraverso [PlannerService] (TaskWeaver-inspired), e
/// instrada le query AI chat attraverso [InferenceService].
///
/// I parametri [maxTokens] e [temperature] vengono ora calcolati
/// automaticamente da [InferenceRequest] in base al modelId conosciuto
/// a runtime in [InferenceService._buildLocalRequest]. Il valore passato
/// qui è un default sicuro che vale solo se il modello non è ancora noto.
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
      case TaskType.chat:
      case TaskType.system:
        return _inferenceService.infer(
          InferenceRequest(
            sessionId: 'default',
            prompt: input,
            systemPrompt: systemPrompt,
            isOffline: isOffline,
            // maxTokens e temperature usano i default adattivi di InferenceRequest
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
    // Parametri opzionali: se non passati, InferenceService li sovrascrive
    // con valori adattivi basati sul modello selezionato a runtime.
    // Manteniamo la firma per retrocompatibilità con i chiamanti esistenti.
    int? maxTokens,
    double? temperature,
  }) {
    _logForensic(
      '[ORCHESTRATOR_SEND] session=$sessionId stage=orchestrator.handleStream'
      ' prompt_chars=${input.length} context_turns=${context.length}',
    );
    final type = _analyzer.analyze(input);
    _logForensic(
      '[ORCHESTRATOR_ROUTE] session=$sessionId task_type=${type.name}'
      ' will_stream_inference=${type == TaskType.chat || type == TaskType.system}',
    );
    final contextSnapshot = List<ChatTurn>.unmodifiable(context);

    if (type == TaskType.command) {
      _logForensic(
        '[PRE_STREAM_BYPASS] session=$sessionId boundary=orchestrator.intent_route'
        ' reason=task_type_command target=_executeCommand',
      );
      return Stream.fromFuture(_executeCommand(input));
    }

    if (type == TaskType.plan || type == TaskType.coding) {
      _logForensic(
        '[PRE_STREAM_BYPASS] session=$sessionId boundary=orchestrator.intent_route'
        ' reason=task_type_${type.name} target=_executePlan',
      );
      return Stream.fromFuture(
        _executePlan(input, isOffline: isOffline),
      );
    }

    _logForensic(
      '[PRE_STREAM_FORWARD] session=$sessionId boundary=orchestrator.intent_route'
      ' target=inference_service.stream task_type=${type.name}',
    );

    // Costruisce la request con i default adattivi.
    // InferenceService._buildLocalRequest sovrascriverà maxTokens e temperature
    // con valori calibrati sul modello effettivo una volta risolto.
    return _inferenceService.stream(
      InferenceRequest(
        sessionId: sessionId,
        prompt: input,
        systemPrompt: systemPrompt,
        context: contextSnapshot,
        isOffline: isOffline,
        // Se il chiamante ha passato valori espliciti li rispettiamo,
        // altrimenti usiamo i default adattivi di InferenceRequest.
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
  /// Fallback a una normale chiamata inference quando [PlannerService] non è
  /// configurato (es. durante i test o cold startup prima del DI completo).
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

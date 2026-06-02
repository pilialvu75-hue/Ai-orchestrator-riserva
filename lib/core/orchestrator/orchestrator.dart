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
/// Step 3 – execution engine: classifies the user intent with [IntentAnalyzer],
/// delegates device commands to [ExecutionEngine] (platform-specific), routes
/// planning/coding goals through [PlannerService] (TaskWeaver-inspired), and
/// routes AI chat queries through [InferenceService].
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
          ),
        );
    }
  }

  TokenStream handleStream(
    String input, {
    required String sessionId,
    List<ChatTurn> context = const <ChatTurn>[],
    String? systemPrompt,
    bool isOffline = false,
    int maxTokens = 256,
    double temperature = 0.7,
  }) {
    _logForensic(
      '[ORCHESTRATOR_SEND] session=$sessionId stage=orchestrator.handleStream prompt_chars=${input.length} context_turns=${context.length}',
    );
    final type = _analyzer.analyze(input);
    _logForensic(
      '[ORCHESTRATOR_ROUTE] session=$sessionId task_type=${type.name} will_stream_inference=${type == TaskType.chat || type == TaskType.system}',
    );
    final contextSnapshot = List<ChatTurn>.unmodifiable(context);

    if (type == TaskType.command) {
      _logForensic(
        '[PRE_STREAM_BYPASS] session=$sessionId boundary=orchestrator.intent_route reason=task_type_command target=_executeCommand',
      );
      return Stream<InferenceResponse>.fromFuture(_executeCommand(input));
    }

    if (type == TaskType.plan || type == TaskType.coding) {
      _logForensic(
        '[PRE_STREAM_BYPASS] session=$sessionId boundary=orchestrator.intent_route reason=task_type_${type.name} target=_executePlan',
      );
      return Stream<InferenceResponse>.fromFuture(
        _executePlan(input, isOffline: isOffline),
      );
    }

    _logForensic(
      '[PRE_STREAM_FORWARD] session=$sessionId boundary=orchestrator.intent_route target=inference_service.stream task_type=${type.name}',
    );
    return _inferenceService.stream(
      InferenceRequest(
        sessionId: sessionId,
        prompt: input,
        systemPrompt: systemPrompt,
        context: contextSnapshot,
        isOffline: isOffline,
        maxTokens: maxTokens,
        temperature: temperature,
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

  /// Decomposes [input] into a [Plan] and executes it step by step.
  ///
  /// Falls back to a normal inference call when [PlannerService] is not
  /// configured (e.g. during tests or cold startup before full DI wiring).
  Future<InferenceResponse> _executePlan(
    String input, {
    bool isOffline = false,
  }) async {
    final planner = _plannerService;
    if (planner == null) {
      // Graceful degradation: no planner wired — treat as a chat message.
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

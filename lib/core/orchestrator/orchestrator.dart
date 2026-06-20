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
import 'package:ai_orchestrator/core/tools/web_search_tool.dart';
import 'package:flutter/foundation.dart';

/// Central routing layer for all AI calls.
///
/// Classifica l'intent utente con [IntentAnalyzer], delega i comandi
/// device a [ExecutionEngine], instrada planning/coding a [PlannerService],
/// esegue ricerche web tramite [WebSearchTool] e passa i risultati al
/// modello locale, e invia le query chat a [InferenceService].
class Orchestrator {
  static const int _maxWebSearchResults = 5;

  Orchestrator({
    required IntentAnalyzer intentAnalyzer,
    required ExecutionEngine executor,
    required InferenceService inferenceService,
    PlannerService? plannerService,
    WebSearchTool? webSearchTool,
  })  : _analyzer = intentAnalyzer,
        _executor = executor,
        _inferenceService = inferenceService,
        _plannerService = plannerService,
        _webSearchTool = webSearchTool;

  final IntentAnalyzer _analyzer;
  final ExecutionEngine _executor;
  final InferenceService _inferenceService;
  final PlannerService? _plannerService;
  final WebSearchTool? _webSearchTool;

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
        return _handleWebSearch(
          input,
          systemPrompt: systemPrompt,
          isOffline: isOffline,
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

  Future<InferenceResponse> _handleWebSearch(
    String input, {
    required String? systemPrompt,
    required bool isOffline,
  }) async {
    final request = await _buildWebSearchRequest(
      input: input,
      sessionId: 'default',
      context: const [],
      systemPrompt: systemPrompt,
      isOffline: isOffline,
      maxTokens: InferenceRequest.defaultMaxTokens,
      temperature: InferenceRequest.defaultTemperature,
    );

    return _inferenceService.infer(request);
  }

  TokenStream _handleWebSearchStream({
    required String input,
    required String sessionId,
    required List<ChatTurn> context,
    required String? systemPrompt,
    required bool isOffline,
    required int? maxTokens,
    required double? temperature,
  }) async* {
    final request = await _buildWebSearchRequest(
      input: input,
      sessionId: sessionId,
      context: context,
      systemPrompt: systemPrompt,
      isOffline: isOffline,
      maxTokens: maxTokens,
      temperature: temperature,
    );

    yield* _inferenceService.stream(request);
  }

  Future<InferenceRequest> _buildWebSearchRequest({
    required String input,
    required String sessionId,
    required List<ChatTurn> context,
    required String? systemPrompt,
    required bool isOffline,
    required int? maxTokens,
    required double? temperature,
  }) async {
    final webSearchTool = _webSearchTool;
    if (isOffline || webSearchTool == null) {
      _logForensic(
        '[WEB_SEARCH] session=$sessionId enabled=false isOffline=$isOffline'
        ' hasTool=${webSearchTool != null}',
      );
      return InferenceRequest(
        sessionId: sessionId,
        prompt: input,
        systemPrompt: _buildWebSearchEffectiveSystemPrompt(
          baseSystemPrompt: systemPrompt,
          searchContext: _buildWebSearchUnavailableContext(
            _buildWebSearchUnavailableReason(
              isOffline: isOffline,
              hasTool: webSearchTool != null,
            ),
          ),
        ),
        context: context,
        isOffline: false,
        maxTokens: maxTokens ?? InferenceRequest.defaultMaxTokens,
        temperature: temperature ?? InferenceRequest.defaultTemperature,
      );
    }

    try {
      final search = await webSearchTool.execute(<String, dynamic>{
        'query': input,
        'limit': _maxWebSearchResults,
      });
      _logForensic(
        '[WEB_SEARCH] session=$sessionId success=${search.success}'
        ' output_chars=${search.output.length}',
      );

      final searchContext = search.success && search.output.trim().isNotEmpty
          ? _buildSearchContext(search.output)
          : _buildWebSearchUnavailableContext(
              _buildWebSearchUnavailableReason(
                isOffline: false,
                hasTool: true,
              ),
            );

      return InferenceRequest(
        sessionId: sessionId,
        prompt: input,
        systemPrompt: _buildWebSearchEffectiveSystemPrompt(
          baseSystemPrompt: systemPrompt,
          searchContext: searchContext,
        ),
        context: context,
        isOffline: false,
        maxTokens: maxTokens ?? InferenceRequest.defaultMaxTokens,
        temperature: temperature ?? InferenceRequest.defaultTemperature,
      );
    } catch (error) {
      _logForensic(
        '[WEB_SEARCH] session=$sessionId success=false error=$error',
      );
      return InferenceRequest(
        sessionId: sessionId,
        prompt: input,
        systemPrompt: _buildWebSearchEffectiveSystemPrompt(
          baseSystemPrompt: systemPrompt,
          searchContext: _buildWebSearchUnavailableContext(
            'the web search request failed',
          ),
        ),
        context: context,
        isOffline: false,
        maxTokens: maxTokens ?? InferenceRequest.defaultMaxTokens,
        temperature: temperature ?? InferenceRequest.defaultTemperature,
      );
    }
  }

  String _buildSearchContext(String searchOutput) {
    final trimmed = searchOutput.trim();
    return 'Web search results:\n$trimmed';
  }

  String _buildWebSearchEffectiveSystemPrompt({
    required String? baseSystemPrompt,
    required String searchContext,
  }) {
    return [
      if (baseSystemPrompt != null && baseSystemPrompt.trim().isNotEmpty)
        baseSystemPrompt.trim(),
      _buildWebSearchSystemPrompt(),
      searchContext,
    ].join('\n\n');
  }

  String _buildWebSearchUnavailableReason({
    required bool isOffline,
    required bool hasTool,
  }) {
    if (isOffline) {
      return 'the device is offline';
    }
    if (!hasTool) {
      return 'the web search tool is unavailable';
    }
    return 'the web search tool returned no usable results';
  }

  String _buildWebSearchUnavailableContext(String reason) {
    return 'Web search evidence could not be gathered because $reason.';
  }

  /// Guides the model to treat retrieved web results as the primary source.
  String _buildWebSearchSystemPrompt() {
    return 'You are AI Orchestrator. Answer the user using the web search '
        'results in the conversation context as primary evidence. Cite the '
        'most relevant source URLs when possible. If the search results do '
        'not contain enough evidence, say so explicitly.';
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

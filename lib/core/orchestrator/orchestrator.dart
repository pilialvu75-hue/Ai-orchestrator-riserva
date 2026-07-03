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
    _logForensic(
      '[WEBSEARCH_INTENT_DETECTED] input_chars=${input.length} task_type=${type.name}',
    );

    switch (type) {
      case TaskType.command:
        return _executeCommand(input);
      case TaskType.plan:
      case TaskType.coding:
        return _executePlan(input, isOffline: isOffline);
      case TaskType.webSearch:
        _logForensic(
          '[WEBSEARCH_TASK_SELECTED] session=default',
        );
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
      _logForensic(
        '[WEBSEARCH_TASK_SELECTED] session=$sessionId',
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

    final response = await _inferenceService.infer(request);
    _logForensic(
      '[WEBSEARCH_MODEL_RESPONSE] session=default isError=${response.isError} text_chars=${response.text.length}',
    );
    _logForensic(
      '[WEBSEARCH_EXIT] session=default success=${!response.isError}',
    );
    return response;
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
    _logForensic(
      '[WEBSEARCH_MODEL_RESPONSE] session=$sessionId stream_complete=true',
    );
    _logForensic(
      '[WEBSEARCH_EXIT] session=$sessionId stream_complete=true',
    );
  }

  String _extractSearchQuery(String input) {
    var query = input.trim();

    const prefixes = [
      'cerca ',
      'cerca su internet ',
      'cerca online ',
      'search ',
      'search for ',
      'find ',
      'trovami ',
      'notizie su ',
      'news su ',
      'aggiornamenti su ',
    ];

    final lower = query.toLowerCase();

    for (final prefix in prefixes) {
      if (lower.startsWith(prefix)) {
        query = query.substring(prefix.length).trim();
        break;
      }
    }

    return query.isEmpty ? input : query;
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
    // Offline is recorded for diagnostics only; web search availability is
    // intentionally decoupled from runtime mode so LOCAL still supports tools.
    // `isOffline` is diagnostic metadata only in this method; if it is true and
    // a tool exists, the HTTP layer still runs and surfaces timeout/failure
    // diagnostics instead of short-circuiting here.
    _logForensic(
      '[WEBSEARCH_ENTER] session=$sessionId offline_flag=$isOffline hasTool=${webSearchTool != null}',
    );
    if (webSearchTool == null) {
      _logForensic(
        '[WEBSEARCH_EXIT] session=$sessionId success=false reason=tool_missing',
      );
      return InferenceRequest(
        sessionId: sessionId,
        prompt: input,
        systemPrompt: systemPrompt,
        context: context,
        isOffline: false,
        maxTokens: maxTokens ?? InferenceRequest.defaultMaxTokens,
        temperature: temperature ?? InferenceRequest.defaultTemperature,
      );
    }

    try {
      final query = _extractSearchQuery(input);
      _logForensic(
        '[WEBSEARCH_TOOL_FOUND] session=$sessionId tool=${webSearchTool.id}',
      );
      _logForensic(
        '[WEBSEARCH_PROVIDER_SELECTED] session=$sessionId provider=${webSearchTool.runtimeType}',
      );

      final search = await webSearchTool.execute(<String, dynamic>{
        'query': query,
        'limit': _maxWebSearchResults,
      });
      _logForensic(
        '[WEBSEARCH_REQUEST_SENT] session=$sessionId query_chars=${query.length}',
      );

      final hasSearchResults = search.success && search.output.trim().isNotEmpty;
      final searchContext = hasSearchResults ? _buildSearchContext(search.output) : '';
      _logForensic(
        '[WEBSEARCH_CONTEXT_CREATED] session=$sessionId chars=${searchContext.length} empty=${searchContext.isEmpty}',
      );

      return InferenceRequest(
        sessionId: sessionId,
        prompt: input,
        systemPrompt: _buildWebSearchEffectiveSystemPrompt(
          baseSystemPrompt: systemPrompt,
          searchContext: searchContext,
          hasResults: hasSearchResults,
        ),
        context: context,
        isOffline: false,
        maxTokens: maxTokens ?? InferenceRequest.defaultMaxTokens,
        temperature: temperature ?? InferenceRequest.defaultTemperature,
      );
    } catch (error) {
      _logForensic(
        '[WEBSEARCH_EXIT] session=$sessionId success=false error=$error',
      );
      return InferenceRequest(
        sessionId: sessionId,
        prompt: input,
        systemPrompt: systemPrompt,
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
    required bool hasResults,
  }) {
    final sections = <String>[];
    final base = baseSystemPrompt?.trim();

    if (base != null && base.isNotEmpty) {
      sections.add(base);
    }

    if (hasResults && searchContext.trim().isNotEmpty) {
      sections.add(_buildWebSearchSystemPrompt());
      sections.add(searchContext);
      _logForensic(
        '[WEBSEARCH_CONTEXT_INJECTED] chars=${searchContext.length}',
      );
    }

    return sections.join('\n\n');
  }

  /// Guides the model to treat retrieved web results as the primary source.
  String _buildWebSearchSystemPrompt() {
    final prompt = 'You are AI Orchestrator. Answer the user using the web search '
        'results in the conversation context as primary evidence. Cite the '
        'most relevant source URLs when possible. If the search results do '
        'not contain enough evidence, say so explicitly.';
    _logForensic('[WEBSEARCH_PROMPT_FINALIZED] chars=${prompt.length}');
    return prompt;
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

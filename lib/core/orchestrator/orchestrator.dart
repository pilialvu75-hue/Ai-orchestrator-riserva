import 'package:ai_orchestrator/core/orchestrator/execution_engine.dart';
import 'package:ai_orchestrator/core/orchestrator/intent_analyzer.dart';
import 'package:ai_orchestrator/core/orchestrator/task_type.dart';
import 'package:ai_orchestrator/core/planner/planner_service.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_constants.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:ai_orchestrator/core/tools/web_search_tool.dart';
import 'package:flutter/foundation.dart';

/// Central routing layer for Assistant/Hybrid AI calls.
///
/// Explicit Cloud chat does not depend on this class: it enters the inference
/// runtime directly through ChatRepository. In Hybrid mode this class owns the
/// Local/Cloud decision and binds the concrete Cloud provider before execution.
class Orchestrator {
  static const int _maxWebSearchResults = 5;

  Orchestrator({
    required IntentAnalyzer intentAnalyzer,
    required ExecutionEngine executor,
    required InferenceService inferenceService,
    PlannerService? plannerService,
    WebSearchTool? webSearchTool,
    AiRuntimeSettingsService? runtimeSettingsService,
    CloudRuntimeProvider? cloudRuntimeProvider,
  })  : _analyzer = intentAnalyzer,
        _executor = executor,
        _inferenceService = inferenceService,
        _plannerService = plannerService,
        _webSearchTool = webSearchTool,
        _runtimeSettingsService = runtimeSettingsService,
        _cloudRuntimeProvider = cloudRuntimeProvider;

  final IntentAnalyzer _analyzer;
  final ExecutionEngine _executor;
  final InferenceService _inferenceService;
  final PlannerService? _plannerService;
  final WebSearchTool? _webSearchTool;
  final AiRuntimeSettingsService? _runtimeSettingsService;
  final CloudRuntimeProvider? _cloudRuntimeProvider;

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
        _logForensic('[WEBSEARCH_TASK_SELECTED] session=default');
        return _handleWebSearch(
          input,
          systemPrompt: systemPrompt,
          isOffline: isOffline,
        );
      case TaskType.chat:
      case TaskType.system:
        final request = _routeRequest(
          InferenceRequest(
            sessionId: 'default',
            prompt: input,
            systemPrompt: systemPrompt,
            isOffline: isOffline,
          ),
        );
        return _inferenceService.infer(request);
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
      _logForensic('[WEBSEARCH_TASK_SELECTED] session=$sessionId');
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

    final request = _routeRequest(
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

    _logForensic(
      '[PRE_STREAM_FORWARD] session=$sessionId'
      ' boundary=orchestrator.intent_route'
      ' target=inference_service.stream task_type=${type.name}'
      ' directive=${request.routeDirective.name}'
      ' cloud_provider=${request.cloudProviderId ?? 'none'}',
    );

    return _inferenceService.stream(request);
  }

  /// Converts persisted runtime mode into an explicit execution decision.
  ///
  /// In Hybrid, CloudRuntimeProvider is used only as a health/capability
  /// adviser. The Orchestrator owns the final Local/Cloud decision and writes
  /// the provider binding into the request. The runtime is then forbidden from
  /// silently switching provider inside that request.
  InferenceRequest _routeRequest(InferenceRequest request) {
    final settings = _runtimeSettingsService;
    if (settings == null) return request;

    switch (settings.runtimeMode) {
      case AiRuntimeMode.local:
        _logRoutingDecision(request, 'local', null);
        return request.copyWith(
          routeDirective: InferenceRouteDirective.localOnly,
          allowCloudProviderFailover: false,
        );

      case AiRuntimeMode.cloud:
        // Normally explicit Cloud chat bypasses the Orchestrator completely.
        // This branch keeps other Orchestrator callers safe and deterministic.
        _logRoutingDecision(request, 'cloud-direct', null);
        return request.copyWith(
          routeDirective: InferenceRouteDirective.cloudOnly,
          allowCloudProviderFailover: true,
        );

      case AiRuntimeMode.hybrid:
        final cloud = _cloudRuntimeProvider;
        if (cloud != null &&
            !request.isOffline &&
            cloud.shouldPreferCloudFor(request)) {
          final provider = cloud.recommendProviderFor(
            request,
            enforceAutomaticPolicy: true,
          );

          if (provider != null) {
            _logRoutingDecision(request, 'hybrid-cloud', provider);
            return request.copyWith(
              routeDirective: InferenceRouteDirective.cloudOnly,
              cloudProviderId: provider,
              allowCloudProviderFailover: false,
            );
          }
        }

        _logRoutingDecision(request, 'hybrid-local', null);
        return request.copyWith(
          routeDirective: InferenceRouteDirective.localOnly,
          allowCloudProviderFailover: false,
        );
    }
  }

  void _logRoutingDecision(
    InferenceRequest request,
    String decision,
    String? provider,
  ) {
    _logForensic(
      '[HYBRID_ROUTING_DECISION]'
      ' session=${request.sessionId}'
      ' decision=$decision'
      ' provider=${provider ?? 'none'}'
      ' prompt_chars=${request.prompt.length}',
    );
  }

  Future<InferenceResponse> _handleWebSearch(
    String input, {
    required String? systemPrompt,
    required bool isOffline,
  }) async {
    final request = _routeRequest(
      await _buildWebSearchRequest(
        input: input,
        sessionId: 'default',
        context: const [],
        systemPrompt: systemPrompt,
        isOffline: isOffline,
        maxTokens: InferenceRequest.defaultMaxTokens,
        temperature: InferenceRequest.defaultTemperature,
      ),
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
    final request = _routeRequest(
      await _buildWebSearchRequest(
        input: input,
        sessionId: sessionId,
        context: context,
        systemPrompt: systemPrompt,
        isOffline: isOffline,
        maxTokens: maxTokens,
        temperature: temperature,
      ),
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
        isOffline: isOffline,
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
        isOffline: isOffline,
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
        isOffline: isOffline,
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

    final cleanedContext = searchContext.trim();
    final isUsableResult = hasResults &&
        cleanedContext.isNotEmpty &&
        !cleanedContext.toLowerCase().contains('no search results found');

    if (isUsableResult) {
      sections.add(_buildWebSearchSystemPrompt());
      sections.add(searchContext);
      _logForensic(
        '[WEBSEARCH_CONTEXT_INJECTED] chars=${searchContext.length}',
      );
    }

    return sections.join('\n\n');
  }

  String _buildWebSearchSystemPrompt() {
    const prompt = 'You are AI Orchestrator. Answer the user using the web search '
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
    final baseRequest = InferenceRequest(
      sessionId: 'planner_session',
      prompt: input,
      isOffline: isOffline,
    );
    final routed = _routeRequest(baseRequest);

    final planner = _plannerService;
    if (planner == null) {
      return _inferenceService.infer(routed);
    }

    final plan = await planner.decompose(
      input,
      isOffline: isOffline,
      routeDirective: routed.routeDirective,
      cloudProviderId: routed.cloudProviderId,
      allowCloudProviderFailover: routed.allowCloudProviderFailover,
    );

    return InferenceResponse.finalChunk(
      text: plan.toDisplayString(),
      model: InferenceConstants.localModelName,
      tokensGenerated: plan.steps.length,
    );
  }
}

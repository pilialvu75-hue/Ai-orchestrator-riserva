import 'dart:collection';

import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_response.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_provider_catalog.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

class CloudRuntimeProvider implements RuntimeInferenceProvider {
  static const int _maxContextLines = 8;
  static const int _maxCacheEntries = 40;
  static const int _summarySourceLines = 4;
  static const int _summaryWordsPerLine = 12;
  static const Duration _rateLimitBackoff = Duration(minutes: 2);

  CloudRuntimeProvider({
    required Future<AiResponse> Function(String provider, AiRequest request) sendQuery,
    required List<String> Function() supportedProviders,
    required bool Function(String provider) isProviderAvailable,
    required String Function([String? providerName]) providerDisplayName,
  })  : _sendQuery = sendQuery,
        _supportedProviders = supportedProviders,
        _isProviderAvailable = isProviderAvailable,
        _providerDisplayName = providerDisplayName;

  static const String fullyLocalNotice =
      'Cloud AI unavailable — running fully local mode.';

  final Future<AiResponse> Function(String provider, AiRequest request) _sendQuery;
  final List<String> Function() _supportedProviders;
  final bool Function(String provider) _isProviderAvailable;
  final String Function([String? providerName]) _providerDisplayName;

  final Map<String, _ProviderHealth> _providerHealth = <String, _ProviderHealth>{};
  final LinkedHashMap<String, AiResponse> _responseCache = LinkedHashMap<String, AiResponse>();
  bool _pendingLocalFallbackNotice = false;

  bool get canInfer => _supportedProviders().any(_isProviderReady);

  bool get areAllProvidersUnavailable =>
      _supportedProviders().every((provider) => !_isProviderReady(provider));

  String? consumeRuntimeNotice() {
    if (!_pendingLocalFallbackNotice) return null;
    _pendingLocalFallbackNotice = false;
    return fullyLocalNotice;
  }

  bool shouldFallBackToLocal(String? message) {
    if (message == null || message == fullyLocalNotice) return false;
    final normalized = message.toLowerCase();
    return normalized.contains('not configured') ||
        normalized.contains('authentication failed') ||
        normalized.contains('verify your api key') ||
        normalized.contains('rate limit') ||
        normalized.contains('quota') ||
        normalized.contains('all providers unavailable');
  }

  bool shouldPreferCloudFor(InferenceRequest request) {
    final signal = _taskSignal(request);
    return signal == _TaskSignal.coding || signal == _TaskSignal.reasoning;
  }

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {
    if (cancellationToken.isCancelled) {
      yield InferenceResponse.error(
        'Inference cancelled.',
        state: InferenceTerminalState.cancelled,
      );
      return;
    }

    if (!canInfer) {
      _pendingLocalFallbackNotice = true;
      yield InferenceResponse.error(
        fullyLocalNotice,
        state: InferenceTerminalState.modelUnavailable,
      );
      return;
    }

    final optimized = _optimizeRequest(request);
    final providerOrder = _providerOrder(optimized);
    final cacheKey = _cacheKey(providerOrder, optimized);
    final cached = _responseCache[cacheKey];
    if (cached != null) {
      yield InferenceResponse.finalChunk(
        text: cached.text,
        tokensGenerated: cached.tokensUsed,
        model: cached.model,
      );
      return;
    }

    String? lastError;
    for (final provider in providerOrder) {
      if (!_isProviderReady(provider)) continue;
      if (cancellationToken.isCancelled) {
        yield InferenceResponse.error(
          'Inference cancelled.',
          state: InferenceTerminalState.cancelled,
        );
        return;
      }
      try {
        final response = await _sendQuery(
          provider,
          AiRequest(
            prompt: optimized.prompt,
            systemPrompt: optimized.systemPrompt,
            maxTokens: optimized.maxTokens,
            temperature: optimized.temperature,
          ),
        );
        if (cancellationToken.isCancelled) {
          yield InferenceResponse.error(
            'Inference cancelled.',
            state: InferenceTerminalState.cancelled,
          );
          return;
        }
        _markSuccess(provider);
        _putCache(cacheKey, response);
        yield InferenceResponse.finalChunk(
          text: response.text,
          tokensGenerated: response.tokensUsed,
          model: response.model,
        );
        return;
      } catch (error) {
        final mapped = _mapError(error, provider);
        _markFailure(provider, mapped);
        lastError = mapped;
      }
    }

    if (areAllProvidersUnavailable) {
      _pendingLocalFallbackNotice = true;
      yield InferenceResponse.error(
        fullyLocalNotice,
        state: InferenceTerminalState.modelUnavailable,
      );
      return;
    }
    yield InferenceResponse.error(lastError ?? 'Cloud AI request failed.');
  }

  InferenceRequest _optimizeRequest(InferenceRequest request) {
    final deduped = <ChatTurn>[];
    final seen = <String>{};
    for (final item in request.context) {
      final normalized = ChatTurn(
        role: item.role,
        content: item.content.trim(),
      );
      if (normalized.content.isEmpty) continue;
      final key = '${normalized.role.name}:${normalized.content.toLowerCase()}';
      if (seen.add(key)) deduped.add(normalized);
    }

    final recent = deduped.length > _maxContextLines
        ? deduped.sublist(deduped.length - _maxContextLines)
        : deduped;
    final older = deduped.length > _maxContextLines
        ? deduped.sublist(0, deduped.length - _maxContextLines)
        : const <ChatTurn>[];

    final summary = older.isEmpty ? '' : _summarizeContext(older);
    final compressedPrompt = StringBuffer();
    if (summary.isNotEmpty) {
      compressedPrompt.writeln('Context summary: $summary');
      compressedPrompt.writeln();
    }
    if (recent.isNotEmpty) {
      compressedPrompt.writeln('Recent context:');
      for (final turn in recent) {
        compressedPrompt.writeln('- ${turn.role.name}: ${turn.content}');
      }
      compressedPrompt.writeln();
    }
    compressedPrompt.write(request.prompt.trim());
    return request.copyWith(
      prompt: compressedPrompt.toString(),
      context: const <ChatTurn>[],
    );
  }

  String _summarizeContext(List<ChatTurn> turns) {
    final snippets = <String>[];
    for (final turn in turns.take(_summarySourceLines)) {
      final line = '${turn.role.name}: ${turn.content}';
      final words = line.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
      if (words.isEmpty) continue;
      snippets.add(words.take(_summaryWordsPerLine).join(' '));
    }
    return snippets.join(' | ');
  }

  _TaskSignal _taskSignal(InferenceRequest request) {
    final contextText = request.context
        .map((turn) => '${turn.role.name}: ${turn.content}')
        .join('\n');
    final text = '${request.systemPrompt ?? ''}\n$contextText\n${request.prompt}'
        .toLowerCase();
    if (_containsAny(text, _codingKeywords)) return _TaskSignal.coding;
    if (_containsAny(text, _reasoningKeywords)) return _TaskSignal.reasoning;
    return _TaskSignal.general;
  }

  List<String> _providerOrder(InferenceRequest request) {
    final available = _supportedProviders();
    final ordered = <String>[];
    switch (_taskSignal(request)) {
      case _TaskSignal.coding:
        ordered.addAll(CloudProviderCatalog.codingPriority);
        break;
      case _TaskSignal.reasoning:
        ordered.addAll(CloudProviderCatalog.reasoningPriority);
        break;
      case _TaskSignal.general:
        ordered.addAll(CloudProviderCatalog.generalPriority);
        break;
    }
    ordered.addAll(available);
    final deduped = <String>[];
    for (final provider in ordered) {
      if (!deduped.contains(provider) && available.contains(provider)) {
        deduped.add(provider);
      }
    }
    return deduped;
  }

  bool _isProviderReady(String provider) {
    if (!_isProviderAvailable(provider)) return false;
    final state = _providerHealth.putIfAbsent(provider, () => _ProviderHealth());
    if (state.quotaExhausted) return false;
    if (state.rateLimitedUntil != null &&
        state.rateLimitedUntil!.isAfter(DateTime.now())) {
      return false;
    }
    return true;
  }

  void _markSuccess(String provider) {
    final state = _providerHealth.putIfAbsent(provider, () => _ProviderHealth());
    state.totalRequests++;
    state.failedRequests = 0;
    state.lastError = null;
    state.rateLimitedUntil = null;
  }

  void _markFailure(String provider, String message) {
    final normalized = message.toLowerCase();
    final state = _providerHealth.putIfAbsent(provider, () => _ProviderHealth());
    state.totalRequests++;
    state.failedRequests++;
    state.lastError = message;
    if (normalized.contains('rate limit') || normalized.contains('429')) {
      state.rateLimitedUntil = DateTime.now().add(_rateLimitBackoff);
    }
    if (normalized.contains('quota') ||
        normalized.contains('credit') ||
        normalized.contains('insufficient')) {
      state.quotaExhausted = true;
    }
  }

  String _cacheKey(List<String> providerOrder, InferenceRequest request) {
    final contentHash = Object.hash(
      request.systemPrompt ?? '',
      request.prompt,
      request.maxTokens,
      request.temperature,
    );
    return '${providerOrder.join(">")}::$contentHash';
  }

  void _putCache(String key, AiResponse value) {
    _responseCache[key] = value;
    while (_responseCache.length > _maxCacheEntries) {
      _responseCache.remove(_responseCache.keys.first);
    }
  }

  String _mapError(Object error, String provider) {
    final rawMessage = error is Failure ? error.message : error.toString();
    final normalized = rawMessage.toLowerCase();
    if (normalized.trim().isEmpty) {
      return '${_providerDisplayName(provider)} is unavailable right now.';
    }
    if (normalized.contains('cancelled')) {
      return 'Inference cancelled.';
    }
    if (normalized.contains('401') ||
        normalized.contains('403') ||
        normalized.contains('unauthorized') ||
        normalized.contains('invalid api key') ||
        normalized.contains('authentication')) {
      return '${_providerDisplayName(provider)} authentication failed.';
    }
    if (normalized.contains('429') || normalized.contains('rate limit')) {
      return '${_providerDisplayName(provider)} rate limit reached.';
    }
    if (normalized.contains('quota') ||
        normalized.contains('credit') ||
        normalized.contains('insufficient')) {
      return '${_providerDisplayName(provider)} quota unavailable.';
    }
    if (normalized.contains('socketexception') ||
        normalized.contains('network') ||
        normalized.contains('connection')) {
      return '${_providerDisplayName(provider)} network unavailable.';
    }
    if (normalized.contains('not configured')) {
      return '${_providerDisplayName(provider)} not configured.';
    }
    return rawMessage;
  }

  bool _containsAny(String text, Set<String> values) {
    for (final value in values) {
      if (text.contains(value)) return true;
    }
    return false;
  }

  static const Set<String> _codingKeywords = <String>{
    'code',
    'coding',
    'bug',
    'debug',
    'refactor',
    'algorithm',
    'function',
    'class',
    'typescript',
    'flutter',
    'dart',
    'python',
    'java',
    'rust',
    'stack trace',
  };

  static const Set<String> _reasoningKeywords = <String>{
    'reason',
    'reasoning',
    'analyze',
    'analysis',
    'compare',
    'tradeoff',
    'proof',
    'explain why',
    'decision',
    'strategy',
    'plan',
  };
}

class _ProviderHealth {
  int totalRequests = 0;
  int failedRequests = 0;
  bool quotaExhausted = false;
  String? lastError;
  DateTime? rateLimitedUntil;
}

enum _TaskSignal { general, coding, reasoning }

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

enum CloudProviderOperationalState {
  ready,
  authRequired,
  rateLimited,
  quotaExhausted,
  temporarilyUnavailable,
  error,
}

class CloudProviderStatusSnapshot {
  const CloudProviderStatusSnapshot({
    required this.providerId,
    required this.state,
    required this.modelId,
    required this.totalRequests,
    required this.failedRequests,
    this.lastError,
    this.retryAt,
    this.averageLatencyMs,
  });

  final String providerId;
  final CloudProviderOperationalState state;
  final String modelId;
  final int totalRequests;
  final int failedRequests;
  final String? lastError;
  final DateTime? retryAt;
  final double? averageLatencyMs;

  double get successRate {
    if (totalRequests <= 0) return 1.0;
    return ((totalRequests - failedRequests) / totalRequests)
        .clamp(0.0, 1.0)
        .toDouble();
  }
}

class CloudRuntimeProvider implements RuntimeInferenceProvider {
  static const int _maxContextTurns = 24;
  static const int _maxCacheEntries = 40;
  static const Duration _rateLimitBackoff = Duration(minutes: 2);
  static const Duration _quotaBackoff = Duration(minutes: 15);
  static const Duration _temporaryFailureBackoff = Duration(seconds: 20);

  CloudRuntimeProvider({
    required Future<AiResponse> Function(String provider, AiRequest request)
        sendQuery,
    required List<String> Function() supportedProviders,
    required bool Function(String provider) isProviderAvailable,
    required String Function([String? providerName]) providerDisplayName,
    String? Function(String provider)? modelForProvider,
    String? Function()? preferredProvider,
  })  : _sendQuery = sendQuery,
        _supportedProviders = supportedProviders,
        _isProviderAvailable = isProviderAvailable,
        _providerDisplayName = providerDisplayName,
        _modelForProvider = modelForProvider,
        _preferredProvider = preferredProvider;

  static const String fullyLocalNotice =
      'Cloud AI unavailable — running fully local mode.';

  final Future<AiResponse> Function(String provider, AiRequest request)
      _sendQuery;
  final List<String> Function() _supportedProviders;
  final bool Function(String provider) _isProviderAvailable;
  final String Function([String? providerName]) _providerDisplayName;
  final String? Function(String provider)? _modelForProvider;
  final String? Function()? _preferredProvider;

  final Map<String, _ProviderHealth> _providerHealth = <String, _ProviderHealth>{};
  final LinkedHashMap<String, AiResponse> _responseCache =
      LinkedHashMap<String, AiResponse>();
  bool _pendingLocalFallbackNotice = false;

  bool get canInfer => _supportedProviders().any(_isProviderReady);

  bool get areAllProvidersUnavailable =>
      _supportedProviders().every((provider) => !_isProviderReady(provider));

  List<CloudProviderStatusSnapshot> get providerStatuses =>
      _supportedProviders().map(_statusFor).toList(growable: false);

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
    final signal = _taskSignal(optimized);
    final providerOrder = _providerOrder(signal);
    final cacheKey = _cacheKey(providerOrder, optimized, signal);
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

      final stopwatch = Stopwatch()..start();
      try {
        final selectedModel = _selectedModel(provider);
        final response = await _sendQuery(
          provider,
          AiRequest(
            prompt: optimized.prompt.trim(),
            systemPrompt: optimized.systemPrompt,
            messages: _toAiMessages(optimized.context),
            maxTokens: optimized.maxTokens,
            temperature: optimized.temperature,
            modelId: selectedModel,
            providerId: provider,
            taskType: signal.name,
            metadata: <String, dynamic>{
              'sessionId': optimized.sessionId,
            },
          ),
        );
        stopwatch.stop();

        if (cancellationToken.isCancelled) {
          yield InferenceResponse.error(
            'Inference cancelled.',
            state: InferenceTerminalState.cancelled,
          );
          return;
        }

        _markSuccess(provider, stopwatch.elapsedMilliseconds);
        _putCache(cacheKey, response);
        yield InferenceResponse.finalChunk(
          text: response.text,
          tokensGenerated: response.tokensUsed,
          model: response.model,
        );
        return;
      } catch (error) {
        stopwatch.stop();
        final mapped = _mapError(error, provider);
        _markFailure(provider, mapped, stopwatch.elapsedMilliseconds);
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

  /// Cloud optimization is deliberately loss-minimizing. It removes empty,
  /// excluded and exact duplicate turns and bounds only very old history. It
  /// never serializes conversation history into the current user prompt.
  InferenceRequest _optimizeRequest(InferenceRequest request) {
    final deduped = <ChatTurn>[];
    final seen = <String>{};

    for (final item in request.context) {
      if (item.excludeFromContext) continue;
      final content = item.content.trim();
      if (content.isEmpty) continue;

      final key = '${item.role.name}:${content.toLowerCase()}';
      if (!seen.add(key)) continue;

      deduped.add(
        ChatTurn(
          role: item.role,
          content: content,
        ),
      );
    }

    final bounded = deduped.length > _maxContextTurns
        ? deduped.sublist(deduped.length - _maxContextTurns)
        : deduped;

    return request.copyWith(
      prompt: request.prompt.trim(),
      context: List<ChatTurn>.unmodifiable(bounded),
    );
  }

  List<AiMessage> _toAiMessages(List<ChatTurn> turns) {
    return turns
        .map(
          (turn) => AiMessage(
            role: switch (turn.role) {
              ChatRole.system => AiMessageRole.system,
              ChatRole.assistant => AiMessageRole.assistant,
              ChatRole.user => AiMessageRole.user,
            },
            content: turn.content,
          ),
        )
        .toList(growable: false);
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

  List<String> _providerOrder(_TaskSignal signal) {
    final available = _supportedProviders().toList(growable: false);
    final preferred = _preferredProvider?.call();
    final indexed = <_ProviderCandidate>[];

    for (var index = 0; index < available.length; index++) {
      final provider = available[index];
      final capability = switch (signal) {
        _TaskSignal.coding => CloudProviderCapability.coding,
        _TaskSignal.reasoning => CloudProviderCapability.reasoning,
        _TaskSignal.general => CloudProviderCapability.general,
      };

      var score = 0.0;
      if (CloudProviderCatalog.supports(provider, capability)) score += 100;
      if (CloudProviderCatalog.supports(
        provider,
        CloudProviderCapability.general,
      )) {
        score += 10;
      }
      if (preferred != null && preferred == provider) score += 25;

      final health = _providerHealth[provider];
      if (health != null) {
        score += health.successRate * 20;
        if (health.averageLatencyMs != null) {
          score -= (health.averageLatencyMs! / 1000)
              .clamp(0.0, 15.0)
              .toDouble();
        }
        score -= health.consecutiveFailures * 12;
      } else {
        score += 20;
      }

      if (!_isProviderReady(provider)) score -= 10000;

      indexed.add(
        _ProviderCandidate(
          providerId: provider,
          score: score,
          originalIndex: index,
        ),
      );
    }

    indexed.sort((a, b) {
      final score = b.score.compareTo(a.score);
      return score != 0 ? score : a.originalIndex.compareTo(b.originalIndex);
    });

    return indexed.map((candidate) => candidate.providerId).toList(growable: false);
  }

  String _selectedModel(String provider) {
    final override = _modelForProvider?.call(provider)?.trim();
    if (override != null && override.isNotEmpty) {
      return override;
    }
    return CloudProviderCatalog.defaultModelFor(provider);
  }

  bool _isProviderReady(String provider) {
    if (!_isProviderAvailable(provider)) return false;
    final state = _providerHealth.putIfAbsent(provider, _ProviderHealth.new);
    final now = DateTime.now();

    if (state.rateLimitedUntil != null && state.rateLimitedUntil!.isAfter(now)) {
      return false;
    }
    if (state.quotaBlockedUntil != null && state.quotaBlockedUntil!.isAfter(now)) {
      return false;
    }
    if (state.unavailableUntil != null && state.unavailableUntil!.isAfter(now)) {
      return false;
    }

    return true;
  }

  void _markSuccess(String provider, int latencyMs) {
    final state = _providerHealth.putIfAbsent(provider, _ProviderHealth.new);
    state.totalRequests++;
    state.successfulRequests++;
    state.consecutiveFailures = 0;
    state.lastError = null;
    state.rateLimitedUntil = null;
    state.quotaBlockedUntil = null;
    state.unavailableUntil = null;
    state.recordLatency(latencyMs);
  }

  void _markFailure(String provider, String message, int latencyMs) {
    final normalized = message.toLowerCase();
    final state = _providerHealth.putIfAbsent(provider, _ProviderHealth.new);
    state.totalRequests++;
    state.failedRequests++;
    state.consecutiveFailures++;
    state.lastError = message;
    state.recordLatency(latencyMs);

    final now = DateTime.now();
    if (normalized.contains('rate limit') || normalized.contains('429')) {
      state.rateLimitedUntil = now.add(_rateLimitBackoff);
      return;
    }
    if (normalized.contains('quota') ||
        normalized.contains('credit') ||
        normalized.contains('insufficient')) {
      state.quotaBlockedUntil = now.add(_quotaBackoff);
      return;
    }
    if (normalized.contains('network') ||
        normalized.contains('connection') ||
        normalized.contains('unavailable')) {
      state.unavailableUntil = now.add(_temporaryFailureBackoff);
    }
  }

  CloudProviderStatusSnapshot _statusFor(String provider) {
    final health = _providerHealth.putIfAbsent(provider, _ProviderHealth.new);
    final now = DateTime.now();
    final configured = _isProviderAvailable(provider);

    if (!configured) {
      return CloudProviderStatusSnapshot(
        providerId: provider,
        state: CloudProviderOperationalState.authRequired,
        modelId: _selectedModel(provider),
        totalRequests: health.totalRequests,
        failedRequests: health.failedRequests,
        lastError: health.lastError,
        averageLatencyMs: health.averageLatencyMs,
      );
    }

    if (health.rateLimitedUntil?.isAfter(now) ?? false) {
      return _snapshot(
        provider,
        health,
        CloudProviderOperationalState.rateLimited,
        retryAt: health.rateLimitedUntil,
      );
    }
    if (health.quotaBlockedUntil?.isAfter(now) ?? false) {
      return _snapshot(
        provider,
        health,
        CloudProviderOperationalState.quotaExhausted,
        retryAt: health.quotaBlockedUntil,
      );
    }
    if (health.unavailableUntil?.isAfter(now) ?? false) {
      return _snapshot(
        provider,
        health,
        CloudProviderOperationalState.temporarilyUnavailable,
        retryAt: health.unavailableUntil,
      );
    }
    if (health.lastError != null && health.consecutiveFailures > 0) {
      return _snapshot(
        provider,
        health,
        CloudProviderOperationalState.error,
      );
    }

    return _snapshot(provider, health, CloudProviderOperationalState.ready);
  }

  CloudProviderStatusSnapshot _snapshot(
    String provider,
    _ProviderHealth health,
    CloudProviderOperationalState state, {
    DateTime? retryAt,
  }) {
    return CloudProviderStatusSnapshot(
      providerId: provider,
      state: state,
      modelId: _selectedModel(provider),
      totalRequests: health.totalRequests,
      failedRequests: health.failedRequests,
      lastError: health.lastError,
      retryAt: retryAt,
      averageLatencyMs: health.averageLatencyMs,
    );
  }

  String _cacheKey(
    List<String> providerOrder,
    InferenceRequest request,
    _TaskSignal signal,
  ) {
    final contextHash = Object.hashAll(
      request.context.map(
        (turn) => Object.hash(turn.role.name, turn.content),
      ),
    );
    final modelsHash = Object.hashAll(
      providerOrder.map((provider) => _selectedModel(provider)),
    );
    final contentHash = Object.hash(
      request.systemPrompt ?? '',
      request.prompt,
      contextHash,
      modelsHash,
      signal.name,
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

class _ProviderCandidate {
  const _ProviderCandidate({
    required this.providerId,
    required this.score,
    required this.originalIndex,
  });

  final String providerId;
  final double score;
  final int originalIndex;
}

class _ProviderHealth {
  int totalRequests = 0;
  int successfulRequests = 0;
  int failedRequests = 0;
  int consecutiveFailures = 0;
  String? lastError;
  DateTime? rateLimitedUntil;
  DateTime? quotaBlockedUntil;
  DateTime? unavailableUntil;
  double? averageLatencyMs;

  double get successRate {
    if (totalRequests <= 0) return 1.0;
    return (successfulRequests / totalRequests)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  void recordLatency(int latencyMs) {
    if (latencyMs < 0) return;
    averageLatencyMs = averageLatencyMs == null
        ? latencyMs.toDouble()
        : (averageLatencyMs! * 0.7) + (latencyMs * 0.3);
  }
}

enum _TaskSignal { general, coding, reasoning }

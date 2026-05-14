import 'dart:async';

import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_constants.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_session.dart';
import 'package:ai_orchestrator/core/runtime/inference/stream_text_accumulator.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:flutter/foundation.dart';

class InferenceService {
  static const _logTag = 'INFERENCE';
  static const Duration _requestTimeout = Duration(minutes: 4);
  static const Duration _streamIdleTimeout = Duration(seconds: 75);
  static const int _maxRetryCount = 1;
  static const int _maxChunksPerRequest = 4096;
  static const Duration _duplicatePromptWindow = Duration(seconds: 3);

  InferenceService({
    required Future<AiModel?> Function() loadSelectedModel,
    required Future<AiRuntimeMode> Function() loadRuntimeMode,
    required LocalRuntimeProvider runtimeProvider,
    required CloudRuntimeProvider cloudRuntimeProvider,
  })  : _loadSelectedModel = loadSelectedModel,
        _loadRuntimeMode = loadRuntimeMode,
        _runtimeProvider = runtimeProvider,
        _cloudRuntimeProvider = cloudRuntimeProvider;

  final Future<AiModel?> Function() _loadSelectedModel;
  final Future<AiRuntimeMode> Function() _loadRuntimeMode;
  final LocalRuntimeProvider _runtimeProvider;
  final CloudRuntimeProvider _cloudRuntimeProvider;

  final Map<String, RuntimeSession> _sessions = <String, RuntimeSession>{};
  final Set<String> _activeSessionIds = <String>{};
  final Map<String, _PromptFingerprint> _lastPromptBySession =
      <String, _PromptFingerprint>{};

  RuntimeSession createSession(String sessionId) {
    return _sessions.putIfAbsent(
      sessionId,
      () => RuntimeSession(sessionId: sessionId),
    );
  }

  void cancel(String sessionId) {
    _log('cancel requested session=$sessionId');
    _sessions[sessionId]?.cancellationToken.cancel();
    _sessions.remove(sessionId);
  }

  TokenStream stream(InferenceRequest request) async* {
    final promptHash = _promptHash(request);
    _log(
      'prompt creation session=${request.sessionId} prompt_hash=$promptHash prompt_chars=${request.prompt.length} '
      'context_lines=${request.context.length} offline=${request.isOffline}',
    );
    if (!_tryAcquirePromptGuard(
      sessionId: request.sessionId,
      promptHash: promptHash,
    )) {
      _log(
        'duplicate prompt guard blocked session=${request.sessionId} prompt_hash=$promptHash',
      );
      yield InferenceResponse.error(
        'Duplicate prompt detected; previous inference is still active.',
      );
      return;
    }

    final session = createSession(request.sessionId);
    try {
      final runtimeMode = await _loadRuntimeMode();
      _log(
        'prompt routing session=${request.sessionId} mode=${runtimeMode.name} prompt_hash=$promptHash',
      );

      final selectedModel = await _resolveSelectedModelForLocalRuntime();
      final localRequest = _buildLocalRequest(request, selectedModel);
      _log(
        'model selection session=${request.sessionId} selected_model=${selectedModel?.id ?? 'none'} '
        'local_runtime_connected=${localRequest != null}',
      );

      yield* _streamWithRetryAndGuards(
        runtimeMode: runtimeMode,
        cloudRequest: request,
        localRequest: localRequest,
        cancellationToken: session.cancellationToken,
      );
    } finally {
      _sessions.remove(request.sessionId);
      _activeSessionIds.remove(request.sessionId);
      _log('async listener cleanup session=${request.sessionId}');
      _log('stream end session=${request.sessionId}');
    }
  }

  Future<InferenceResponse> infer(InferenceRequest request) async {
    final buffer = StringBuffer();
    String model = InferenceConstants.localModelName;
    int tokens = 0;
    int timestamp = DateTime.now().millisecondsSinceEpoch;

    await for (final chunk in stream(request)) {
      _log(
        'infer chunk session=${request.sessionId} isFinal=${chunk.isFinal} isError=${chunk.isError} '
        'text_len=${chunk.text.length} tokens=${chunk.tokensGenerated} notice=${chunk.runtimeNotice != null}',
      );
      if (chunk.isError) {
        return InferenceResponse.error(
          chunk.errorMessage ?? 'Inference failed.',
        );
      }
      if (chunk.isFinal) {
        if (chunk.text.isNotEmpty) {
          final merged = mergeStreamedText(
            currentText: buffer.toString(),
            incomingText: chunk.text,
            isFinalChunk: true,
          );
          buffer.clear();
          buffer.write(merged);
        }
        model = chunk.model ?? model;
        tokens = chunk.tokensGenerated;
        timestamp = chunk.timestamp;
      } else {
        buffer.write(chunk.text);
        model = chunk.model ?? model;
      }
    }

    return InferenceResponse(
      text: buffer.toString(),
      model: model,
      tokensGenerated: tokens,
      timestamp: timestamp,
      isFinal: true,
    );
  }

  Future<AiModel?> _resolveSelectedModelForLocalRuntime() async {
    AiModel? selected;
    try {
      selected = await _loadSelectedModel();
    } catch (_) {
      // Model selection load failures are treated as "no local model" so
      // inference can continue via cloud fallback.
      return null;
    }

    if (selected == null ||
        !selected.isDownloaded ||
        selected.localPath == null ||
        selected.validationStatus == ModelValidationStatus.invalidModel ||
        selected.validationStatus == ModelValidationStatus.missingFile ||
        selected.validationStatus == ModelValidationStatus.notDownloaded ||
        selected.validationStatus == ModelValidationStatus.downloading ||
        !_runtimeProvider.supportsModel(selected)) {
      _log('memory retrieval/model validation local model unavailable');
      return null;
    }
    _log(
      'memory retrieval/model validation local model ready id=${selected.id} path=${selected.localPath}',
    );
    return selected;
  }

  InferenceRequest? _buildLocalRequest(
    InferenceRequest request,
    AiModel? selectedModel,
  ) {
    if (selectedModel == null || selectedModel.localPath == null) return null;
    return request.copyWith(
      modelId: selectedModel.effectiveRuntimeModelId,
      modelPath: selectedModel.localPath,
    );
  }

  TokenStream _streamLocalInference({
    required InferenceRequest localRequest,
    required InferenceRequest cloudRequest,
    required CancellationToken cancellationToken,
    required bool allowCloudFallback,
  }) async* {
    var emittedLocalToken = false;
    var localChunkCount = 0;
    await for (final chunk in _runtimeProvider.streamInference(
      request: localRequest,
      cancellationToken: cancellationToken,
    )) {
      localChunkCount++;
      _log(
        'local chunk session=${localRequest.sessionId} chunk=$localChunkCount '
        'isFinal=${chunk.isFinal} isError=${chunk.isError} text_len=${chunk.text.length} '
        'tokens=${chunk.tokensGenerated} notice=${chunk.runtimeNotice}',
      );
      if (chunk.isError &&
          allowCloudFallback &&
          !emittedLocalToken &&
          _cloudRuntimeProvider.canInfer) {
        _log(
          'fallback routing session=${localRequest.sessionId} from=local to=cloud reason=${chunk.errorMessage}',
        );
        yield InferenceResponse.notice(
          'Local runtime failed, switching to cloud runtime.',
        );
        yield* _cloudRuntimeProvider.streamInference(
          request: cloudRequest,
          cancellationToken: cancellationToken,
        );
        return;
      }

      if (!chunk.isError && !chunk.isFinal && chunk.text.isNotEmpty) {
        emittedLocalToken = true;
      }

      yield chunk;
    }
    _log(
      'local stream end session=${localRequest.sessionId} emittedLocalToken=$emittedLocalToken chunks=$localChunkCount',
    );
  }

  TokenStream _streamWithRetryAndGuards({
    required AiRuntimeMode runtimeMode,
    required InferenceRequest cloudRequest,
    required InferenceRequest? localRequest,
    required CancellationToken cancellationToken,
  }) async* {
    for (var attempt = 1; attempt <= _maxRetryCount + 1; attempt++) {
      var emittedContent = false;
      var shouldRetry = false;
      var retryReason = '';
      final routedStream = _routeInference(
        runtimeMode: runtimeMode,
        cloudRequest: cloudRequest,
        localRequest: localRequest,
        cancellationToken: cancellationToken,
      );
      await for (final chunk in _guardInferenceStream(
        stream: routedStream,
        sessionId: cloudRequest.sessionId,
        cancellationToken: cancellationToken,
        attempt: attempt,
      )) {
        if (chunk.runtimeNotice != null && chunk.runtimeNotice!.trim().isNotEmpty) {
          _log(
            'streaming callbacks session=${cloudRequest.sessionId} notice="${chunk.runtimeNotice}"',
          );
          yield chunk;
          continue;
        }
        if (chunk.text.trim().isNotEmpty) {
          emittedContent = true;
        }
        if (chunk.isError &&
            attempt <= _maxRetryCount &&
            !emittedContent &&
            _isRetryableError(chunk.errorMessage)) {
          shouldRetry = true;
          retryReason = chunk.errorMessage ?? 'transient runtime failure';
          _log(
            'retry handler session=${cloudRequest.sessionId} attempt=$attempt reason="$retryReason"',
          );
          continue;
        }
        _log(
          'response parsing session=${cloudRequest.sessionId} attempt=$attempt isFinal=${chunk.isFinal} '
          'isError=${chunk.isError} text_len=${chunk.text.length}',
        );
        yield chunk;
        if (chunk.isFinal) {
          return;
        }
      }
      if (!shouldRetry || cancellationToken.isCancelled) {
        return;
      }
      yield InferenceResponse.notice(
        'Transient runtime issue detected, retrying once.',
      );
    }
  }

  TokenStream _routeInference({
    required AiRuntimeMode runtimeMode,
    required InferenceRequest cloudRequest,
    required InferenceRequest? localRequest,
    required CancellationToken cancellationToken,
  }) {
    switch (runtimeMode) {
      case AiRuntimeMode.local:
        if (localRequest != null) {
          return _streamLocalInference(
            localRequest: localRequest,
            cloudRequest: cloudRequest,
            cancellationToken: cancellationToken,
            allowCloudFallback: true,
          );
        }
        return Stream<InferenceResponse>.value(
          InferenceResponse.error(
            'Local AI mode requires a downloaded validated model. Please download one in Settings > Models or switch to Cloud or Hybrid mode.',
          ),
        );
      case AiRuntimeMode.cloud:
        return _streamAutomaticOrchestration(
          cloudRequest: cloudRequest,
          localRequest: localRequest,
          cancellationToken: cancellationToken,
          forceCloudPrimary: true,
        );
      case AiRuntimeMode.hybrid:
        return _streamAutomaticOrchestration(
          cloudRequest: cloudRequest,
          localRequest: localRequest,
          cancellationToken: cancellationToken,
        );
    }
  }

  TokenStream _guardInferenceStream({
    required TokenStream stream,
    required String sessionId,
    required CancellationToken cancellationToken,
    required int attempt,
  }) async* {
    final startedAt = DateTime.now();
    var chunkCount = 0;
    await for (final chunk in stream.timeout(
      _streamIdleTimeout,
      onTimeout: (sink) {
        cancellationToken.cancel();
        sink.add(
          InferenceResponse.error(
            'Inference stream timed out waiting for tokens.',
          ),
        );
        sink.close();
      },
    )) {
      chunkCount++;
      if (chunkCount > _maxChunksPerRequest) {
        cancellationToken.cancel();
        _log(
          'hard stop protection session=$sessionId attempt=$attempt max_chunks=$_maxChunksPerRequest',
        );
        yield InferenceResponse.error(
          'Inference stopped after exceeding safe stream chunk limit.',
        );
        return;
      }
      if (DateTime.now().difference(startedAt) > _requestTimeout) {
        cancellationToken.cancel();
        _log(
          'hard stop protection session=$sessionId attempt=$attempt request_timeout_ms=${_requestTimeout.inMilliseconds}',
        );
        yield InferenceResponse.error(
          'Inference request timed out.',
        );
        return;
      }
      yield chunk;
    }
  }

  bool _tryAcquirePromptGuard({
    required String sessionId,
    required String promptHash,
  }) {
    final now = DateTime.now();
    final last = _lastPromptBySession[sessionId];
    final isRapidDuplicate = last != null &&
        last.hash == promptHash &&
        now.difference(last.at) <= _duplicatePromptWindow;
    if (_activeSessionIds.contains(sessionId) || isRapidDuplicate) {
      return false;
    }
    _activeSessionIds.add(sessionId);
    _lastPromptBySession[sessionId] = _PromptFingerprint(promptHash, now);
    return true;
  }

  bool _isRetryableError(String? errorMessage) {
    final normalized = (errorMessage ?? '').toLowerCase();
    return normalized.contains('timeout') ||
        normalized.contains('timed out') ||
        normalized.contains('stalled') ||
        normalized.contains('tempor') ||
        normalized.contains('network');
  }

  // Stable request fingerprint used only for rapid duplicate suppression inside
  // `_duplicatePromptWindow` to prevent auto-retriggered inference loops.
  String _promptHash(InferenceRequest request) {
    return Object.hash(
      request.sessionId,
      request.prompt.trim(),
      request.systemPrompt?.trim() ?? '',
      request.context.join('\n'),
    ).toRadixString(16);
  }

  TokenStream _streamAutomaticOrchestration({
    required InferenceRequest cloudRequest,
    required InferenceRequest? localRequest,
    required CancellationToken cancellationToken,
    bool forceCloudPrimary = false,
  }) async* {
    if (cloudRequest.isOffline) {
      if (localRequest != null) {
        _log(
          'fallback routing session=${cloudRequest.sessionId} from=cloud to=local reason=offline',
        );
        yield* _streamLocalInference(
          localRequest: localRequest,
          cloudRequest: cloudRequest,
          cancellationToken: cancellationToken,
          allowCloudFallback: false,
        );
        return;
      }
      yield InferenceResponse.error(
        'Device is offline and no validated local model is selected.',
      );
      return;
    }

    final shouldPreferCloud =
        forceCloudPrimary || _cloudRuntimeProvider.shouldPreferCloudFor(cloudRequest);

    if (!shouldPreferCloud && localRequest != null) {
      _log(
        'routing session=${cloudRequest.sessionId} mode=local-first cloudPreferred=$shouldPreferCloud',
      );
      yield* _streamLocalInference(
        localRequest: localRequest,
        cloudRequest: cloudRequest,
        cancellationToken: cancellationToken,
        allowCloudFallback: true,
      );
      return;
    }

    await for (final chunk in _cloudRuntimeProvider.streamInference(
      request: cloudRequest,
      cancellationToken: cancellationToken,
    )) {
      if (chunk.runtimeNotice != null && chunk.runtimeNotice!.trim().isNotEmpty) {
        yield chunk;
        continue;
      }
      if (chunk.isError) {
        if (localRequest != null &&
            _cloudRuntimeProvider.shouldFallBackToLocal(chunk.errorMessage)) {
          _log(
            'fallback routing session=${cloudRequest.sessionId} from=cloud to=local reason=${chunk.errorMessage}',
          );
          final notice = _cloudRuntimeProvider.consumeRuntimeNotice();
          if (notice != null) {
            yield InferenceResponse.notice(notice);
          }
          yield* _streamLocalInference(
            localRequest: localRequest,
            cloudRequest: cloudRequest,
            cancellationToken: cancellationToken,
            allowCloudFallback: false,
          );
          return;
        }
      }
      yield chunk;
    }
  }

  static void _log(String message) {
    debugPrint('[$_logTag] $message');
  }

}

class _PromptFingerprint {
  const _PromptFingerprint(this.hash, this.at);

  final String hash;
  final DateTime at;
}

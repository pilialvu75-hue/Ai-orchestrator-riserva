import 'dart:async';

import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_constants.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_session_manager.dart';
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

  InferenceService({
    required Future<AiModel?> Function() loadSelectedModel,
    required Future<AiRuntimeMode> Function() loadRuntimeMode,
    required LocalRuntimeProvider runtimeProvider,
    required CloudRuntimeProvider cloudRuntimeProvider,
    required RuntimeSessionManager sessionManager,
  })  : _loadSelectedModel = loadSelectedModel,
        _loadRuntimeMode = loadRuntimeMode,
        _runtimeProvider = runtimeProvider,
        _cloudRuntimeProvider = cloudRuntimeProvider,
        _sessionManager = sessionManager;

  final Future<AiModel?> Function() _loadSelectedModel;
  final Future<AiRuntimeMode> Function() _loadRuntimeMode;
  final LocalRuntimeProvider _runtimeProvider;
  final CloudRuntimeProvider _cloudRuntimeProvider;
  final RuntimeSessionManager _sessionManager;

  void cancel(String sessionId) {
    _log('cancel requested session=$sessionId');
    _sessionManager.cancel(sessionId);
  }

  TokenStream stream(InferenceRequest request) async* {
    _log('[ORCHESTRATOR_BEGIN] session=${request.sessionId}');
    _log(
      '[RUNTIME_PATH] stream_start session=${request.sessionId} provider=${_runtimeProvider.runtimeType}',
    );
    final promptHash = _promptHash(request);
    _log(
      'prompt creation session=${request.sessionId} prompt_hash=$promptHash prompt_chars=${request.prompt.length} '
      'context_lines=${request.context.length} offline=${request.isOffline}',
    );

    final session = _sessionManager.startSession(request.sessionId);
    try {
      final runtimeMode = await _loadRuntimeMode();
      _log(
        '[RUNTIME_PATH] routing session=${request.sessionId} mode=${runtimeMode.name} '
        'provider=${_runtimeProvider.runtimeType} prompt_hash=$promptHash',
      );

      final selectedModel = await _resolveSelectedModelForLocalRuntime();
      final localRequest = _buildLocalRequest(request, selectedModel);
      _log(
        '[MODEL_LOAD] selection session=${request.sessionId} selected_model=${selectedModel?.id ?? 'none'} '
        'local_runtime_connected=${localRequest != null} path=${selectedModel?.localPath ?? 'none'}',
      );

      yield* _streamWithRetryAndGuards(
        runtimeMode: runtimeMode,
        cloudRequest: request,
        localRequest: localRequest,
        cancellationToken: session.cancellationToken,
      );
    } finally {
      _sessionManager.complete(session);
      _log('async listener cleanup session=${request.sessionId}');
      _log('stream end session=${request.sessionId}');
      _log('[ORCHESTRATOR_END] session=${request.sessionId}');
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
    } on Exception catch (e) {
      _log(
        '[VALIDATION] reason=model_selection_exception detail=$e – falling back to cloud',
      );
      return null;
    }

    if (selected == null) {
      _log('[VALIDATION] reason=selected_null – no model has been chosen');
      return null;
    }

    if (!selected.isDownloaded) {
      _log(
        '[VALIDATION] reason=model_not_downloaded'
        ' modelId=${selected.id} displayName="${selected.displayName}"',
      );
      return null;
    }

    if (selected.localPath == null || selected.localPath!.trim().isEmpty) {
      _log(
        '[VALIDATION] reason=localPath_missing'
        ' modelId=${selected.id} localPath=${selected.localPath}',
      );
      return null;
    }

    if (selected.validationStatus == ModelValidationStatus.invalidModel) {
      _log(
        '[VALIDATION] reason=invalidModel'
        ' modelId=${selected.id} path=${selected.localPath}',
      );
      return null;
    }

    if (selected.validationStatus == ModelValidationStatus.missingFile) {
      _log(
        '[VALIDATION] reason=missingFile'
        ' modelId=${selected.id} path=${selected.localPath}',
      );
      return null;
    }

    if (selected.validationStatus == ModelValidationStatus.notDownloaded) {
      _log(
        '[VALIDATION] reason=notDownloaded'
        ' modelId=${selected.id}',
      );
      return null;
    }

    if (selected.validationStatus == ModelValidationStatus.downloading) {
      _log(
        '[VALIDATION] reason=downloading – model transfer in progress'
        ' modelId=${selected.id}',
      );
      return null;
    }

    if (!_runtimeProvider.supportsModel(selected)) {
      // Infer the precise reason for the runtime rejection so the log is
      // actionable rather than a generic "unavailable" message.
      final effectiveId = selected.effectiveRuntimeModelId;
      final vs = selected.validationStatus;
      String rejectionReason;
      if (vs != ModelValidationStatus.validatedOk) {
        rejectionReason = 'unsupported_quantization_or_validation_status'
            ' (validationStatus=$vs)';
      } else {
        rejectionReason =
            'runtime_provider_incompatibility – modelId="$effectiveId"'
            ' not in validated set; possible unsupported architecture'
            ' or tokenizer mismatch';
      }
      _log(
        '[VALIDATION] reason=$rejectionReason'
        ' modelId=${selected.id}'
        ' effectiveRuntimeModelId=$effectiveId'
        ' validationStatus=$vs'
        ' path=${selected.localPath}',
      );
      return null;
    }

    _log(
      '[VALIDATION] status=ok modelId=${selected.id}'
      ' effectiveRuntimeModelId=${selected.effectiveRuntimeModelId}'
      ' path=${selected.localPath}',
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
        '[TOKEN_STREAM] local chunk session=${localRequest.sessionId} chunk=$localChunkCount '
        'isFinal=${chunk.isFinal} isError=${chunk.isError} text_len=${chunk.text.length} '
        'tokens=${chunk.tokensGenerated} notice=${chunk.runtimeNotice}',
      );
      if (chunk.isError &&
          _isStalledPreInferenceError(chunk.errorMessage)) {
        cancellationToken.cancel();
        _log(
          '[TERMINAL_STATE] state=stalled_pre_inference session=${localRequest.sessionId}'
          ' stage=local_stream_guard',
        );
      }
      if (chunk.isError &&
          allowCloudFallback &&
          !emittedLocalToken &&
          _cloudRuntimeProvider.canInfer) {
        _log(
          '[RUNTIME_PATH] fallback session=${localRequest.sessionId} from=local to=cloud reason=${chunk.errorMessage}',
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
      '[FINAL_RESPONSE] local stream end session=${localRequest.sessionId} emittedLocalToken=$emittedLocalToken chunks=$localChunkCount',
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
            '[TOKEN_STREAM] notice session=${cloudRequest.sessionId} notice="${chunk.runtimeNotice}"',
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
            '[RUNTIME_PATH] retry session=${cloudRequest.sessionId} attempt=$attempt reason="$retryReason"',
          );
          continue;
        }
        _log(
          '[FINAL_RESPONSE] session=${cloudRequest.sessionId} attempt=$attempt isFinal=${chunk.isFinal} '
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
        _log(
          '[RUNTIME_PATH] mode=local session=${cloudRequest.sessionId} local_request=${localRequest != null}',
        );
        if (localRequest != null) {
          return _streamLocalInference(
            localRequest: localRequest,
            cloudRequest: cloudRequest,
            cancellationToken: cancellationToken,
            allowCloudFallback: false,
          );
        }
        return Stream<InferenceResponse>.value(
          InferenceResponse.error(
            'Local AI mode requires a downloaded validated model. Please download one in Settings > Models or switch to Cloud or Hybrid mode.',
          ),
        );
      case AiRuntimeMode.cloud:
        _log('[RUNTIME_PATH] mode=cloud session=${cloudRequest.sessionId}');
        return _streamAutomaticOrchestration(
          cloudRequest: cloudRequest,
          localRequest: localRequest,
          cancellationToken: cancellationToken,
          forceCloudPrimary: true,
        );
      case AiRuntimeMode.hybrid:
        _log('[RUNTIME_PATH] mode=hybrid session=${cloudRequest.sessionId}');
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
            state: InferenceTerminalState.timeout,
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
          state: InferenceTerminalState.timeout,
        );
        return;
      }
      yield chunk;
    }
  }

  bool _isRetryableError(String? errorMessage) {
    final normalized = (errorMessage ?? '').toLowerCase();
    return normalized.contains('timeout') ||
        normalized.contains('timed out') ||
        normalized.contains('stalled') ||
        normalized.contains('tempor') ||
        normalized.contains('network');
  }

  bool _isStalledPreInferenceError(String? errorMessage) {
    final normalized = (errorMessage ?? '').toLowerCase();
    return normalized.contains('stage=stalled_pre_inference') ||
        normalized.contains('stalled_pre_inference');
  }

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
    RuntimeEventLog.instance.emit(message);
  }
}

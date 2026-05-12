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
    final session = createSession(request.sessionId);
    final runtimeMode = await _loadRuntimeMode();
    _log(
      'stream start session=${request.sessionId} mode=${runtimeMode.name} prompt_chars=${request.prompt.length}',
    );

    final selectedModel = await _resolveSelectedModelForLocalRuntime();
    final localRequest = _buildLocalRequest(request, selectedModel);

    switch (runtimeMode) {
      case AiRuntimeMode.local:
        if (localRequest != null) {
          yield* _streamLocalInference(
            localRequest: localRequest,
            cloudRequest: request,
            cancellationToken: session.cancellationToken,
            allowCloudFallback: true,
          );
        } else {
          yield InferenceResponse.error(
            'Local AI mode requires a downloaded validated model. Please download one in Settings > Models or switch to Cloud or Hybrid mode.',
          );
        }
        break;
      case AiRuntimeMode.cloud:
        yield* _streamAutomaticOrchestration(
          cloudRequest: request,
          localRequest: localRequest,
          cancellationToken: session.cancellationToken,
          forceCloudPrimary: true,
        );
        break;
      case AiRuntimeMode.hybrid:
        yield* _streamAutomaticOrchestration(
          cloudRequest: request,
          localRequest: localRequest,
          cancellationToken: session.cancellationToken,
        );
        break;
    }

    _sessions.remove(request.sessionId);
    _log('stream end session=${request.sessionId}');
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
      return null;
    }
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

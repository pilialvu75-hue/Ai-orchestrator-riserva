import 'dart:async';
import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_session_manager.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';

class InferenceService {
  final Future<AiModel?> Function() _loadSelectedModel;
  final Future<AiRuntimeMode> Function() _loadRuntimeMode;
  final LocalRuntimeProvider _runtimeProvider;
  final CloudRuntimeProvider _cloudRuntimeProvider;
  final RuntimeSessionManager _sessionManager;

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

  void cancel(String sessionId) {
    _sessionManager.cancel(sessionId);
  }

  TokenStream stream(InferenceRequest request) async* {
    final session = _sessionManager.startSession(request.sessionId);
    
    try {
      final runtimeMode = await _loadRuntimeMode();
      final selectedModel = await _loadSelectedModel();
      
      if (selectedModel != null) {
        _runtimeProvider.supportsModel(selectedModel);
      }

      // Costruzione resiliente: usa lo selectedModel se presente, altrimenti preserva i dati della request
      final localRequest = request.copyWith(
        modelId: selectedModel?.effectiveRuntimeModelId ?? request.modelId,
        modelPath: selectedModel?.localPath ?? request.modelPath,
      );

      // 1. MODALITÀ LOCALE
      if (runtimeMode == AiRuntimeMode.local || request.isOffline) {
        await for (final chunk in _runtimeProvider.streamInference(
          request: localRequest,
          cancellationToken: session.cancellationToken,
        )) {
          yield chunk;
        }
      } else {
        // 2. MODALITÀ IBRIDA / CLOUD
        final shouldPreferCloud = runtimeMode == AiRuntimeMode.cloud ||
            _cloudRuntimeProvider.shouldPreferCloudFor(request);

        if (!shouldPreferCloud) {
          // Gestione Fallback Ibrido su fallimento Startup Locale
          var emittedLocalToken = false;
          var localStartupFailed = false;

          await for (final chunk in _runtimeProvider.streamInference(
            request: localRequest,
            cancellationToken: session.cancellationToken,
          )) {
            if (chunk.isError && !emittedLocalToken) {
              localStartupFailed = true;
              break;
            }
            if (chunk.text.isNotEmpty) emittedLocalToken = true;
            yield chunk;
          }

          if (localStartupFailed) {
            await for (final chunk in _cloudRuntimeProvider.streamInference(
              request: request,
              cancellationToken: session.cancellationToken,
            )) {
              yield chunk;
            }
          }
        } else {
          // Fallback da Cloud a Locale (Errori autenticazione/rete)
          await for (final chunk in _cloudRuntimeProvider.streamInference(
            request: request,
            cancellationToken: session.cancellationToken,
          )) {
            if (chunk.isError && _cloudRuntimeProvider.shouldFallBackToLocal(chunk.errorMessage)) {
              await for (final localChunk in _runtimeProvider.streamInference(
                request: localRequest,
                cancellationToken: session.cancellationToken,
              )) {
                yield localChunk;
              }
              return;
            }
            yield chunk;
          }
        }
      }
    } catch (error) {
      yield InferenceResponse.error('Inference service error: $error');
    } finally {
      _sessionManager.complete(session);
    }
  }

  Future<InferenceResponse> infer(InferenceRequest request) async {
    final buffer = StringBuffer();
    String model = 'local';
    int tokens = 0;
    int timestamp = DateTime.now().millisecondsSinceEpoch;

    await for (final chunk in stream(request)) {
      if (chunk.isError) {
        return InferenceResponse.error(chunk.errorMessage ?? 'Inference failed.');
      }
      buffer.write(chunk.text);
      if (chunk.isFinal) {
        model = chunk.model ?? model;
        tokens = chunk.tokensGenerated;
        timestamp = chunk.timestamp;
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
}

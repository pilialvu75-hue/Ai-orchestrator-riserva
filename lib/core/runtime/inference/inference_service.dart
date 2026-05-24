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

      // 1. MODALITÀ LOCALE REQUISITO: richiesta intatta + token della sessione corrente
      if (runtimeMode == AiRuntimeMode.local || request.isOffline) {
        yield* _runtimeProvider.streamInference(
          request: request,
          cancellationToken: session.cancellationToken,
        );
      } else {
        // 2. MODALITÀ CLOUD CON FALLBACK
        bool cloudFailed = false;
        
        try {
          await for (final chunk in _cloudRuntimeProvider.streamInference(
            request: request,
            cancellationToken: session.cancellationToken,
          )) {
            if (chunk.isError) {
              cloudFailed = true;
              break;
            }
            yield chunk;
          }
        } catch (_) {
          cloudFailed = true;
        }

        // Se il cloud fallisce l'autenticazione/handshake, scala sul locale
        if (cloudFailed) {
          yield* _runtimeProvider.streamInference(
            request: request,
            cancellationToken: session.cancellationToken,
          );
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

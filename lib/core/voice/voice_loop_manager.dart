import 'dart:async';

import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/ai/providers/local_ai_repository.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/voice/voice_engine.dart';

/// Manages the closed-loop Voice-to-Voice pipeline.
///
/// Live mode deliberately bypasses the normal Chat UI / Bloc / repository
/// pipeline for conversation history.
///
/// Flow:
///
///   microphone -> STT -> selected local model -> inference -> TTS
///
/// The selected local model is resolved from LocalAiRepository immediately
/// before inference. This prevents Live mode from creating an
/// InferenceRequest without modelId/modelPath.
///
/// Important:
/// - No ChatRepository is involved.
/// - No conversation-memory window is constructed here.
/// - No semantic workspace context is injected here.
/// - Spoken text is used directly as the inference prompt.
/// - The active local model is resolved from LocalAiRepository.
///
class VoiceLoopManager with RuntimeEventEmitter {
  VoiceLoopManager({
    required VoiceEngine engine,
    required LocalRuntimeProvider runtimeProvider,
    required LocalAiRepository localAiRepository,
  })  : _engine = engine,
        _runtimeProvider = runtimeProvider,
        _localAiRepository = localAiRepository;

  static const String _tag = 'VOICE_LOOP';

  static const Duration _sttTimeout = Duration(seconds: 30);

  final VoiceEngine _engine;
  final LocalRuntimeProvider _runtimeProvider;
  final LocalAiRepository _localAiRepository;

  CancellationToken? _activeCancellation;

  bool _sessionActive = false;
  bool _disposed = false;
  bool _stopRequested = false;

  CancellationToken? get activeCancellationToken => _activeCancellation;

  bool get isSessionActive => _sessionActive;

  /// Permanently disposes this manager.
  ///
  /// VoiceEngine ownership remains with dependency injection.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }

    _disposed = true;

    try {
      await stopLiveSession();
    } catch (_) {
      // Disposal must never propagate an audio/native exception.
    }
  }

  /// Starts one complete Live voice iteration:
  ///
  /// STT -> local inference -> TTS
  ///
  /// [modelPath] and [modelId] are optional compatibility parameters.
  /// If they are not supplied, the manager resolves the currently selected
  /// local model from LocalAiRepository.
  Future<void> startLiveSession({
    String? modelPath,
    String? modelId,
    String? systemPrompt,
    void Function(String text, bool isFinal)? onSubtitle,
    void Function(String error)? onError,
  }) async {
    if (_disposed) {
      return;
    }

    if (_sessionActive) {
      return;
    }

    _sessionActive = true;
    _stopRequested = false;

    final cancellation = CancellationToken();
    _activeCancellation = cancellation;

    try {
      await _runLoop(
        token: cancellation,
        modelPath: modelPath,
        modelId: modelId,
        systemPrompt: systemPrompt,
        onSubtitle: onSubtitle,
        onError: onError,
      );
    } catch (error) {
      if (!cancellation.isCancelled && !_stopRequested) {
        final message = 'Voice session failed: $error';

        logEvent(
          _tag,
          '[SESSION_ERROR] $message',
        );

        onError?.call(message);
      }
    } finally {
      if (identical(_activeCancellation, cancellation)) {
        _activeCancellation = null;
      }

      _sessionActive = false;
      _stopRequested = false;
    }
  }

  /// Stops the current Live session.
  ///
  /// Cancellation is requested before shutting down the voice engine so
  /// asynchronous callbacks cannot continue into inference/TTS.
  Future<void> stopLiveSession() async {
    _stopRequested = true;

    final cancellation = _activeCancellation;
    cancellation?.cancel();

    try {
      await _engine.stopListening();
    } catch (_) {
      // Native audio shutdown must never escape UI lifecycle code.
    }

    try {
      await _engine.stopSpeaking();
    } catch (_) {
      // Native audio shutdown must never escape UI lifecycle code.
    }

    _sessionActive = false;
  }

  /// Resolves the model that Live must use.
  ///
  /// Priority:
  ///
  /// 1. Explicit modelPath/modelId supplied by caller.
  /// 2. Currently selected local model from LocalAiRepository.
  ///
  /// The second path is the normal Live path.
  Future<AiModel?> _resolveSelectedModel({
    String? modelPath,
    String? modelId,
  }) async {
    final explicitPath = modelPath?.trim();
    final explicitId = modelId?.trim();

    if (explicitPath != null &&
        explicitPath.isNotEmpty &&
        explicitId != null &&
        explicitId.isNotEmpty) {
      return null;
    }

    final result = await _localAiRepository.getSelectedModel();

    return result.fold(
      (failure) {
        logEvent(
          _tag,
          '[MODEL_RESOLVE_FAIL] ${failure.message}',
        );

        return null;
      },
      (model) {
        if (model == null) {
          logEvent(
            _tag,
            '[MODEL_RESOLVE_FAIL] no selected local model',
          );
          return null;
        }

        return model;
      },
    );
  }

  /// Resolves modelId/modelPath for the inference request.
  ///
  /// This method never fabricates a model path.
  /// If the selected model does not have a local path, inference is blocked
  /// with a user-visible error instead of sending an invalid request.
  Future<({String? modelId, String? modelPath, String? error})>
      _resolveInferenceModel({
    String? modelPath,
    String? modelId,
  }) async {
    final explicitPath = modelPath?.trim();
    final explicitId = modelId?.trim();

    if (explicitPath != null &&
        explicitPath.isNotEmpty &&
        explicitId != null &&
        explicitId.isNotEmpty) {
      return (
        modelId: explicitId,
        modelPath: explicitPath,
        error: null,
      );
    }

    final selectedModel = await _resolveSelectedModel(
      modelPath: modelPath,
      modelId: modelId,
    );

    if (selectedModel == null) {
      return (
        modelId: null,
        modelPath: null,
        error: 'Nessun modello locale selezionato.',
      );
    }

    final selectedPath = selectedModel.localPath?.trim();

    if (selectedPath == null || selectedPath.isEmpty) {
      logEvent(
        _tag,
        '[MODEL_RESOLVE_FAIL] selected model has no local path '
        'modelId=${selectedModel.effectiveRuntimeModelId}',
      );

      return (
        modelId: selectedModel.effectiveRuntimeModelId,
        modelPath: null,
        error:
            'Il modello locale selezionato non ha un percorso locale valido.',
      );
    }

    return (
      modelId: selectedModel.effectiveRuntimeModelId,
      modelPath: selectedPath,
      error: null,
    );
  }

  Future<void> _runLoop({
    required CancellationToken token,
    required String? modelPath,
    required String? modelId,
    required String? systemPrompt,
    required void Function(String text, bool isFinal)? onSubtitle,
    required void Function(String error)? onError,
  }) async {
    if (_disposed || token.isCancelled) {
      return;
    }

    // -----------------------------------------------------------------------
    // 1. STT
    // -----------------------------------------------------------------------

    final sttCompleter = Completer<String>();

    void completeStt(String text) {
      if (sttCompleter.isCompleted) {
        return;
      }

      final normalized = text.trim();

      if (normalized.isEmpty) {
        return;
      }

      sttCompleter.complete(normalized);
    }

    try {
      await _engine.startListening(
        onResult: (text, isFinal) {
          if (_disposed || token.isCancelled || _stopRequested) {
            return;
          }

          final normalized = text.trim();

          if (normalized.isEmpty) {
            return;
          }

          onSubtitle?.call(normalized, isFinal);

          if (isFinal) {
            completeStt(normalized);
          }
        },
      );
    } catch (error) {
      if (!token.isCancelled && !_stopRequested) {
        final message = 'Voice input failed: $error';

        logEvent(
          _tag,
          '[STT_START_ERROR] $message',
        );

        onError?.call(message);
      }

      return;
    }

    String spokenText;

    try {
      spokenText = await sttCompleter.future.timeout(
        _sttTimeout,
        onTimeout: () => '',
      );
    } catch (error) {
      if (!token.isCancelled && !_stopRequested) {
        final message = 'Voice input timeout: $error';

        logEvent(
          _tag,
          '[STT_WAIT_ERROR] $message',
        );

        onError?.call(message);
      }

      return;
    } finally {
      try {
        await _engine.stopListening();
      } catch (_) {
        // Keep the Live pipeline alive.
      }
    }

    if (_disposed || token.isCancelled || _stopRequested) {
      return;
    }

    spokenText = spokenText.trim();

    if (spokenText.isEmpty) {
      return;
    }

    // -----------------------------------------------------------------------
    // 2. RESOLVE ACTIVE LOCAL MODEL
    // -----------------------------------------------------------------------

    final resolvedModel = await _resolveInferenceModel(
      modelPath: modelPath,
      modelId: modelId,
    );

    if (_disposed || token.isCancelled || _stopRequested) {
      return;
    }

    if (resolvedModel.error != null) {
      final message = resolvedModel.error!;

      logEvent(
        _tag,
        '[MODEL_RESOLVE_ERROR] $message',
      );

      onError?.call(message);
      return;
    }

    final resolvedModelId = resolvedModel.modelId;
    final resolvedModelPath = resolvedModel.modelPath;

    if (resolvedModelId == null ||
        resolvedModelId.isEmpty ||
        resolvedModelPath == null ||
        resolvedModelPath.isEmpty) {
      const message = 'Percorso del modello locale mancante.';

      logEvent(
        _tag,
        '[MODEL_RESOLVE_ERROR] $message',
      );

      onError?.call(message);
      return;
    }

    // -----------------------------------------------------------------------
    // 3. INFERENCE
    // -----------------------------------------------------------------------

    final request = InferenceRequest(
      sessionId: 'voice_loop_${DateTime.now().microsecondsSinceEpoch}',
      prompt: spokenText,
      systemPrompt: systemPrompt,
      isOffline: true,
      maxTokens: 256,
      temperature: 0.7,
      modelId: resolvedModelId,
      modelPath: resolvedModelPath,
    );

    Stream<dynamic> inferenceStream;

    try {
      inferenceStream = _runtimeProvider.streamInference(
        request: request,
        cancellationToken: token,
      );
    } catch (error) {
      if (!token.isCancelled && !_stopRequested) {
        final message = 'Voice inference failed to start: $error';

        logEvent(
          _tag,
          '[INFERENCE_START_ERROR] $message',
        );

        onError?.call(message);
      }

      return;
    }

    // -----------------------------------------------------------------------
    // 4. TOKEN -> TTS
    // -----------------------------------------------------------------------

    final tokenBuffer = StringBuffer();

    final sentenceBoundaryPattern = RegExp(r'[.!?\n]');

    await for (final response in inferenceStream) {
      if (_disposed || token.isCancelled || _stopRequested) {
        break;
      }

      if (response.isError) {
        final message = response.errorMessage ?? 'Voice inference error';

        logEvent(
          _tag,
          '[INFERENCE_ERROR] $message',
        );

        onError?.call(message);
        break;
      }

      final chunk = response.text;

      if (chunk.isEmpty) {
        continue;
      }

      tokenBuffer.write(chunk);

      final currentText = tokenBuffer.toString();

      onSubtitle?.call(
        currentText,
        response.isFinal,
      );

      final shouldFlush =
          response.isFinal ||
          sentenceBoundaryPattern.hasMatch(chunk);

      if (!shouldFlush) {
        continue;
      }

      final speakChunk = tokenBuffer.toString().trim();
      tokenBuffer.clear();

      if (speakChunk.isEmpty) {
        continue;
      }

      if (_disposed || token.isCancelled || _stopRequested) {
        break;
      }

      try {
        await _engine.speak(speakChunk);
      } catch (error) {
        if (!token.isCancelled && !_stopRequested) {
          final message = 'Voice output failed: $error';

          logEvent(
            _tag,
            '[TTS_ERROR] $message',
          );

          onError?.call(message);
        }

        break;
      }
    }

    // -----------------------------------------------------------------------
    // 5. TRAILING TTS
    // -----------------------------------------------------------------------

    if (_disposed || token.isCancelled || _stopRequested) {
      return;
    }

    final trailing = tokenBuffer.toString().trim();

    if (trailing.isEmpty) {
      return;
    }

    try {
      await _engine.speak(trailing);
    } catch (error) {
      if (!token.isCancelled && !_stopRequested) {
        final message = 'Voice output failed: $error';

        logEvent(
          _tag,
          '[TTS_TRAILING_ERROR] $message',
        );

        onError?.call(message);
      }
    }
  }
}

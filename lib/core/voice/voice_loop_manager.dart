import 'dart:async';

import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/voice/voice_engine.dart';

/// Manages the closed-loop Voice-to-Voice pipeline.
///
/// Live mode deliberately bypasses the normal Chat UI / Bloc / repository
/// pipeline. The flow is:
///
///   microphone -> STT -> local inference -> TTS
///
/// The manager owns the lifecycle of one live iteration and protects the
/// pipeline from duplicate starts, cancellation races and asynchronous audio
/// failures.
///
/// Important:
/// - No ChatRepository is involved.
/// - No conversation-memory window is constructed here.
/// - No semantic workspace context is injected here.
/// - The spoken text is used as the inference prompt directly.
///
class VoiceLoopManager with RuntimeEventEmitter {
  VoiceLoopManager({
    required VoiceEngine engine,
    required LocalRuntimeProvider runtimeProvider,
  })  : _engine = engine,
        _runtimeProvider = runtimeProvider;

  static const String _tag = 'VOICE_LOOP';

  static const Duration _sttTimeout = Duration(seconds: 30);

  final VoiceEngine _engine;
  final LocalRuntimeProvider _runtimeProvider;

  CancellationToken? _activeCancellation;

  bool _sessionActive = false;
  bool _disposed = false;
  bool _stopRequested = false;

  /// Token belonging to the currently active live session.
  CancellationToken? get activeCancellationToken => _activeCancellation;

  bool get isSessionActive => _sessionActive;

  /// Permanently disposes this manager.
  ///
  /// The VoiceEngine itself is owned by dependency injection and therefore
  /// isn't disposed here.
  Future<void> dispose() async {
    if (_disposed) return;

    _disposed = true;

    try {
      await stopLiveSession();
    } catch (_) {
      // Disposal must never propagate an audio/native exception.
    }
  }

  /// Starts one Live voice session.
  ///
  /// The session performs one complete:
  ///
  /// STT -> inference -> TTS
  ///
  /// iteration.
  ///
  /// The existing API is intentionally preserved so callers such as
  /// LiveVoiceOverlay don't need to change.
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
  /// Cancellation happens before touching the audio engine so that callbacks
  /// arriving during shutdown cannot start another inference/TTS operation.
  Future<void> stopLiveSession() async {
    _stopRequested = true;

    final cancellation = _activeCancellation;
    cancellation?.cancel();

    try {
      await _engine.stopListening();
    } catch (_) {
      // Native audio shutdown must not escape through UI lifecycle code.
    }

    try {
      await _engine.stopSpeaking();
    } catch (_) {
      // Native audio shutdown must not escape through UI lifecycle code.
    }

    _sessionActive = false;
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

          // Live subtitles are intentionally lightweight. They do not enter
          // ChatRepository or MemoryWindowManager.
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
        // Keep the Live pipeline alive; shutdown errors are non-fatal here.
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
    // 2. INFERENCE
    // -----------------------------------------------------------------------
    //
    // IMPORTANT:
    // The spoken text is sent directly to the local runtime.
    //
    // No ChatRepository.
    // No rolling memory.
    // No semantic retrieval.
    // No UI prompt reconstruction.
    //

    final request = InferenceRequest(
      sessionId: 'voice_loop_${DateTime.now().microsecondsSinceEpoch}',
      prompt: spokenText,
      systemPrompt: systemPrompt,
      isOffline: true,
      maxTokens: 256,
      temperature: 0.7,
      modelId: modelId,
      modelPath: modelPath,
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
    // 3. TOKEN -> TTS
    // -----------------------------------------------------------------------

    final tokenBuffer = StringBuffer();

    // Do not flush on ',' or ';'.
    //
    // Those characters are too frequent in normal model output and can create
    // dozens of tiny TTS requests. This is particularly harmful on mobile.
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
    // 4. TRAILING TTS
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

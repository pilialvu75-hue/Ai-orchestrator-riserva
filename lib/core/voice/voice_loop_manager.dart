import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/voice/voice_engine.dart';

/// Manages the closed-loop Voice-to-Voice pipeline.
///
/// This component is the **preferential lane** that routes audio directly
/// between [VoiceEngine] and [LocalRuntimeProvider] — bypassing the chat UI,
/// its Bloc layer, and the SQLite repositories.  It is inspired by the
/// real-time barge-in design of Gemini Live.
///
/// Pipeline
/// ─────────
/// ```
/// Microphone → [VoiceEngine.startListening]
///             → (final STT text)
///             → [LocalRuntimeProvider.streamInference]
///             → (token stream, punctuation-chunked)
///             → [VoiceEngine.speak]
/// ```
///
/// Barge-in
/// ─────────
/// When the user speaks while TTS is active, [stopLiveSession] cancels the
/// current inference and stops speaking; the loop is re-armed from the top
/// of [startLiveSession].
class VoiceLoopManager with RuntimeEventEmitter {
  VoiceLoopManager({
    required VoiceEngine engine,
    required LocalRuntimeProvider runtimeProvider,
  })  : _engine = engine,
        _runtimeProvider = runtimeProvider;

  static const String _tag = 'VOICE_LOOP';

  final VoiceEngine _engine;
  final LocalRuntimeProvider _runtimeProvider;

  CancellationToken? _activeCancellation;
  bool _sessionActive = false;

  /// The session-level cancellation token; exposed so callers can integrate
  /// with external lifecycle events (e.g. app backgrounding).
  CancellationToken? get activeCancellationToken => _activeCancellation;

  bool get isSessionActive => _sessionActive;

  /// Starts the live Voice-to-Voice loop.
  ///
  /// [modelPath] and [modelId] identify the local GGUF model to use for
  /// inference; if omitted the runtime will use its last validated model.
  /// [systemPrompt] is forwarded verbatim to the LLM.
  /// [onSubtitle] receives real-time subtitle updates when
  /// [VoiceEngineStatus.enableLiveSubtitles] is `true` on the engine status.
  Future<void> startLiveSession({
    String? modelPath,
    String? modelId,
    String? systemPrompt,
    void Function(String text, bool isFinal)? onSubtitle,
    void Function(String error)? onError,
  }) async {
    if (_sessionActive) {
      logEvent(_tag, '[SESSION_START_SKIPPED] session already active');
      return;
    }

    _sessionActive = true;
    _activeCancellation = CancellationToken();

    logEvent(
      _tag,
      '[SESSION_START] modelId=${modelId ?? "auto"} '
      'systemPrompt=${systemPrompt != null ? "set" : "none"}',
    );

    try {
      await _runLoop(
        modelPath: modelPath,
        modelId: modelId,
        systemPrompt: systemPrompt,
        onSubtitle: onSubtitle,
        onError: onError,
      );
    } catch (e, st) {
      final msg = 'VoiceLoopManager fatal error: $e';
      debugPrint('[$_tag] $msg\n$st');
      logEvent(_tag, '[SESSION_FATAL] $msg');
      onError?.call(msg);
    } finally {
      _sessionActive = false;
      _activeCancellation = null;
    }
  }

  /// Stops the active session, cancels ongoing inference, and silences TTS.
  Future<void> stopLiveSession() async {
    if (!_sessionActive) return;
    logEvent(_tag, '[SESSION_STOP_REQUESTED]');
    _activeCancellation?.cancel();
    await _engine.stopListening();
    await _engine.stopSpeaking();
    _sessionActive = false;
    logEvent(_tag, '[SESSION_STOP_DONE]');
  }

  // ── Core loop ─────────────────────────────────────────────────────────────

  Future<void> _runLoop({
    required String? modelPath,
    required String? modelId,
    required String? systemPrompt,
    required void Function(String text, bool isFinal)? onSubtitle,
    required void Function(String error)? onError,
  }) async {
    final token = _activeCancellation!;

    // ── 1. STT: listen until a final result arrives ────────────────────────
    logEvent(_tag, '[STT_LISTEN_BEGIN]');

    final sttCompleter = Completer<String>();

    await _engine.startListening(
      onResult: (text, isFinal) {
        if (token.isCancelled) return;

        // Forward to subtitle callback if enabled.
        onSubtitle?.call(text, isFinal);

        if (isFinal && !sttCompleter.isCompleted) {
          logEvent(_tag, '[STT_FINAL_RESULT] text="${text.length > 80 ? text.substring(0, 80) : text}..."');
          sttCompleter.complete(text);
        }
      },
    );

    // Wait for the first final STT result, respecting cancellation.
    final String spokenText;
    try {
      spokenText = await sttCompleter.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          logEvent(_tag, '[STT_TIMEOUT] No final STT result within 30s');
          return '';
        },
      );
    } finally {
      await _engine.stopListening();
    }

    if (token.isCancelled) {
      logEvent(_tag, '[STT_CANCELLED]');
      return;
    }

    if (spokenText.isEmpty) {
      logEvent(_tag, '[STT_EMPTY_RESULT] skipping inference');
      return;
    }

    // ── 2. LLM inference: stream tokens directly from the runtime ──────────
    logEvent(
      _tag,
      '[INFERENCE_BEGIN] prompt="${spokenText.length > 60 ? spokenText.substring(0, 60) : spokenText}"',
    );

    final request = InferenceRequest(
      sessionId: 'voice_loop_${DateTime.now().millisecondsSinceEpoch}',
      prompt: spokenText,
      systemPrompt: systemPrompt,
      isOffline: true,
      maxTokens: 256,
      temperature: 0.7,
      modelId: modelId,
      modelPath: modelPath,
    );

    final inferenceStream = _runtimeProvider.streamInference(
      request: request,
      cancellationToken: token,
    );

    // ── 3. Token accumulation with punctuation-based TTS chunking ──────────
    // Tokens are buffered until a sentence-boundary character is detected,
    // then the buffered chunk is sent to TTS.  This mirrors the Gemini Live
    // barge-in design where TTS starts before the full response is available.
    final tokenBuffer = StringBuffer();
    final sentenceBoundaryPattern = RegExp(r'[.!?,;:\n]');

    await for (final response in inferenceStream) {
      if (token.isCancelled) {
        logEvent(_tag, '[INFERENCE_CANCELLED]');
        break;
      }

      if (response.isError) {
        final msg = response.errorMessage ?? 'Inference error';
        logEvent(_tag, '[INFERENCE_ERROR] $msg');
        onError?.call(msg);
        break;
      }

      final chunk = response.text;
      if (chunk.isEmpty) continue;

      tokenBuffer.write(chunk);

      // Forward token to subtitle stream.
      onSubtitle?.call(tokenBuffer.toString(), response.isFinal);

      // Flush to TTS on sentence boundary or at final chunk.
      if (response.isFinal || sentenceBoundaryPattern.hasMatch(chunk)) {
        final speakChunk = tokenBuffer.toString().trim();
        tokenBuffer.clear();

        if (speakChunk.isNotEmpty) {
          logEvent(
            _tag,
            '[TTS_CHUNK_FLUSH] length=${speakChunk.length} '
            'isFinal=${response.isFinal}',
          );
          // Barge-in guard: only speak if not cancelled.
          if (!token.isCancelled) {
            unawaited(_engine.speak(speakChunk));
          }
        }
      }
    }

    // Flush any remaining tokens.
    final trailing = tokenBuffer.toString().trim();
    if (trailing.isNotEmpty && !token.isCancelled) {
      logEvent(_tag, '[TTS_TRAILING_FLUSH] length=${trailing.length}');
      unawaited(_engine.speak(trailing));
    }

    logEvent(_tag, '[LOOP_ITERATION_DONE]');
  }
}

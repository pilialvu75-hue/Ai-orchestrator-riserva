import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/voice/voice_engine.dart';

/// Identifies the current stage of the voice STT → LLM → TTS pipeline.
///
/// Exposed via [VoiceLoopManager.currentPhase] so that the UI overlay can
/// display fine-grained diagnostic information without polling.
enum VoicePipelinePhase {
  /// No active pipeline iteration.
  idle,

  /// Microphone is open and the STT engine is processing audio.
  sttListening,

  /// A final STT result has been received and the LLM connection is being
  /// established.
  llmConnecting,

  /// Connection to the LLM is open; waiting for the first response token.
  llmWaitingToken,

  /// Tokens are flowing and TTS chunks are being synthesised / played.
  ttsSynthesizing,
}

extension VoicePipelinePhaseWireName on VoicePipelinePhase {
  String get wireName {
    return switch (this) {
      VoicePipelinePhase.idle => 'idle',
      VoicePipelinePhase.sttListening => 'stt_listening',
      VoicePipelinePhase.llmConnecting => 'llm_connecting',
      VoicePipelinePhase.llmWaitingToken => 'llm_waiting_token',
      VoicePipelinePhase.ttsSynthesizing => 'tts_synthesizing',
    };
  }
}

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
/// Guardrails
/// ──────────
/// • A 15-second safe-timeout fires when no LLM token arrives after connection.
///   The engine immediately speaks an offline diagnostic phrase so the user
///   hears an audible failure notice even when the UI is backgrounded.
/// • A network-error path speaks a different diagnostic phrase when the
///   inference stream cannot be established.
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

  /// Timeout for receiving the first LLM token after stream open.
  static const Duration _llmFirstTokenTimeout = Duration(seconds: 15);

  final VoiceEngine _engine;
  final LocalRuntimeProvider _runtimeProvider;

  CancellationToken? _activeCancellation;
  bool _sessionActive = false;

  VoicePipelinePhase _currentPhase = VoicePipelinePhase.idle;
  String? _pipelineError;

  /// Current pipeline stage; updated at each phase boundary.
  VoicePipelinePhase get currentPhase => _currentPhase;

  /// Non-null when the pipeline ended with an error or timeout.
  String? get pipelineError => _pipelineError;

  /// The session-level cancellation token; exposed so callers can integrate
  /// with external lifecycle events (e.g. app backgrounding).
  CancellationToken? get activeCancellationToken => _activeCancellation;

  bool get isSessionActive => _sessionActive;

  // ── Phase helpers ─────────────────────────────────────────────────────────

  void _setPhase(VoicePipelinePhase phase) {
    _currentPhase = phase;
    logEvent(_tag, '[PHASE] ${phase.wireName}');
  }

  // ── Session lifecycle ─────────────────────────────────────────────────────

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
    _pipelineError = null;

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
      _setPhase(VoicePipelinePhase.idle);
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
    _setPhase(VoicePipelinePhase.idle);
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
    _setPhase(VoicePipelinePhase.sttListening);
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
    _setPhase(VoicePipelinePhase.llmConnecting);
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

    late Stream<InferenceResponse> inferenceStream;
    try {
      inferenceStream = _runtimeProvider.streamInference(
        request: request,
        cancellationToken: token,
      );
    } catch (e) {
      const errMsg =
          'Errore di pipeline. Connessione con il modulo di pensiero fallita.';
      logEvent(_tag, '[INFERENCE_CONNECT_FAIL] $e');
      _pipelineError =
          'STATUS: ${VoicePipelinePhase.llmConnecting.wireName} - ERROR: connection failed';
      onError?.call(_pipelineError!);
      if (!token.isCancelled) {
        unawaited(_engine.speak(errMsg));
      }
      return;
    }

    // ── 3. Token accumulation with punctuation-based TTS chunking ──────────
    // Tokens are buffered until a sentence-boundary character is detected,
    // then the buffered chunk is sent to TTS.  This mirrors the Gemini Live
    // barge-in design where TTS starts before the full response is available.
    final tokenBuffer = StringBuffer();
    final sentenceBoundaryPattern = RegExp(r'[.!?,;:\n]');
    bool firstTokenReceived = false;

    // Timer that fires when no first token has arrived within the safe window.
    Timer? firstTokenTimer;

    try {
      firstTokenTimer = Timer(_llmFirstTokenTimeout, () {
        if (firstTokenReceived || token.isCancelled) return;
        const timeoutPhrase =
            'Errore di pipeline. Timeout di quindici secondi sul primo token dell\'LLM.';
        logEvent(_tag, '[LLM_FIRST_TOKEN_TIMEOUT] 15s elapsed with no token');
        _pipelineError =
            'STATUS: ${VoicePipelinePhase.llmWaitingToken.wireName} - ERROR: Timeout 15s';
        onError?.call(_pipelineError!);
        token.cancel();
        unawaited(_engine.speak(timeoutPhrase));
      });

      _setPhase(VoicePipelinePhase.llmWaitingToken);

      await for (final response in inferenceStream) {
        if (token.isCancelled) {
          logEvent(_tag, '[INFERENCE_CANCELLED]');
          break;
        }

        if (response.isError) {
          final msg = response.errorMessage ?? 'Inference error';
          logEvent(_tag, '[INFERENCE_ERROR] $msg');
          _pipelineError =
              'STATUS: ${_currentPhase.wireName} - ERROR: $msg';
          onError?.call(_pipelineError!);
          const errPhrase =
              'Errore di pipeline. Connessione con il modulo di pensiero fallita.';
          if (!token.isCancelled) {
            unawaited(_engine.speak(errPhrase));
          }
          break;
        }

        final chunk = response.text;
        if (chunk.isEmpty) continue;

        if (!firstTokenReceived) {
          firstTokenReceived = true;
          firstTokenTimer?.cancel();
          firstTokenTimer = null;
          logEvent(_tag, '[LLM_FIRST_TOKEN_RECEIVED]');
        }

        tokenBuffer.write(chunk);

        // Transition to TTS phase on first real token.
        if (_currentPhase != VoicePipelinePhase.ttsSynthesizing) {
          _setPhase(VoicePipelinePhase.ttsSynthesizing);
        }

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
    } finally {
      firstTokenTimer?.cancel();
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

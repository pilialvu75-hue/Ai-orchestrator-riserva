import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;

import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/ai/providers/local_ai_repository.dart';
import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/voice/voice_engine.dart';
import 'package:ai_orchestrator/core/voice/live_voice_latency.dart';
import 'package:ai_orchestrator/core/voice/live_voice_phase.dart';
import 'package:ai_orchestrator/core/voice/live_playback_drain.dart';
import 'package:ai_orchestrator/core/voice/live_speech_sequence.dart';
import 'package:ai_orchestrator/core/voice/live_response_text_assembler.dart';
import 'package:ai_orchestrator/core/voice/read_aloud_transport.dart';

/// Manages the closed-loop Voice-to-Voice pipeline.
///
/// Live mode:
///
///   microphone -> STT -> selected local model -> inference -> TTS
///
/// The normal Chat UI / ChatRepository pipeline is deliberately bypassed.
///
/// STT language is explicitly propagated to the VoiceEngine so Live cannot
/// silently fall back to an English-only/default recognizer configuration.
class VoiceLoopManager with RuntimeEventEmitter {
  VoiceLoopManager({
    required VoiceEngine engine,
    required LocalRuntimeProvider runtimeProvider,
    required LocalAiRepository localAiRepository,
  })  : _engine = engine,
        _runtimeProvider = runtimeProvider,
        _localAiRepository = localAiRepository;

  static const String _tag = 'VOICE_LOOP';

  // The current shipped Live recognizer uses it-IT by default. Live bypasses
  // ChatRepository, so it must explicitly provide the assistant's language
  // instruction. An explicit systemPrompt still takes precedence.
  static const String _defaultLiveItalianSystemPrompt =
      'Sei AIVEXUS in conversazione vocale. Rispondi in italiano '
      'con frasi brevi e naturali. Non cambiare lingua a meno che '
      "l'utente non lo chieda esplicitamente. Non ripetere la risposta.";

  static const Duration _sttTimeout =
      Duration(seconds: 30);

  final VoiceEngine _engine;
  final LocalRuntimeProvider _runtimeProvider;
  final LocalAiRepository _localAiRepository;

  CancellationToken? _activeCancellation;

  bool _sessionActive = false;
  bool _disposed = false;
  bool _stopRequested = false;
  LiveVoicePhase _phase = LiveVoicePhase.idle;

  LiveVoicePhase get phase => _phase;

  CancellationToken? get activeCancellationToken =>
      _activeCancellation;

  bool get isSessionActive =>
      _sessionActive;

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

  Future<void> startLiveSession({
    String? modelPath,
    String? modelId,
    String? systemPrompt,
    Future<void> Function(String text)? onUserTranscript,
    Future<void> Function(String text)? onAssistantTranscript,
    void Function(String text, bool isFinal)?
        onSubtitle,
    void Function(String error)? onError,
    void Function(LiveVoicePhase phase)? onPhase,
  }) async {
    if (_disposed) {
      return;
    }

    if (_sessionActive) {
      return;
    }

    _sessionActive = true;
    _stopRequested = false;

    final cancellation =
        CancellationToken();

    _activeCancellation =
        cancellation;

    final phaseTimeline = LiveVoicePhaseTimeline();
    void notifyPhase(LiveVoicePhase next) {
      final timing = phaseTimeline.transitionTo(next);
      if (timing == null) return;
      _phase = next;
      logEvent(
        _tag,
        '[VOICE_PHASE] previous=${timing.previous.name} '
        'current=${next.name} '
        'stage_ms=${timing.stageMs} total_ms=${timing.totalMs}',
      );
      try {
        onPhase?.call(next);
      } catch (_) {
        // A widget callback must never abort the native voice pipeline.
      }
    }

    notifyPhase(LiveVoicePhase.preparing);

    logEvent(
      _tag,
      '[SESSION_START] '
      'sttLocale=${AppConstants.sttDefaultLocaleId}',
    );

    try {
      await _runLoop(
        token: cancellation,
        modelPath: modelPath,
        modelId: modelId,
        systemPrompt: systemPrompt,
        onUserTranscript: onUserTranscript,
        onAssistantTranscript: onAssistantTranscript,
        onSubtitle: onSubtitle,
        onError: onError,
        notifyPhase: notifyPhase,
      );
    } catch (error) {
      if (!cancellation.isCancelled &&
          !_stopRequested) {
        final message =
            'Voice session failed: $error';

        logEvent(
          _tag,
          '[SESSION_ERROR] $message',
        );

        onError?.call(message);
      }
    } finally {
      // A cancelled/empty Live turn may never reach the normal Android
      // STT -> LLM handoff. Release its native recognizer on every exit,
      // *after* the turn has unwound, before a typed chat request can start.
      // A false result can mean ASR was already released during inference.
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        final recognizer = _engine;
        if (recognizer is VoiceRecognitionMemoryReclaimer) {
          try {
            final freed = await (recognizer as VoiceRecognitionMemoryReclaimer)
                .releaseRecognitionMemoryForInference();
            logEvent(_tag, '[LIVE_END_ASR_RELEASE] released=$freed');
          } catch (error) {
            logEvent(_tag,
                '[LIVE_END_ASR_RELEASE_WARN] type=${error.runtimeType}');
          }
        }
      }

      if (identical(
        _activeCancellation,
        cancellation,
      )) {
        _activeCancellation = null;
      }

      _sessionActive = false;
      _stopRequested = false;
      notifyPhase(LiveVoicePhase.idle);

      logEvent(
        _tag,
        '[SESSION_END]',
      );
    }
  }

  Future<void> stopLiveSession() async {
    _stopRequested = true;

    final cancellation =
        _activeCancellation;

    cancellation?.cancel();

    try {
      await _engine.stopListening();
    } catch (_) {}

    try {
      await _engine.stopSpeaking();
    } catch (_) {}

    // Session stays active until _runLoop completes; a new turn cannot race.
    logEvent(
      _tag,
      '[SESSION_STOP_REQUESTED]',
    );
  }

  Future<AiModel?> _resolveSelectedModel({
    String? modelPath,
    String? modelId,
  }) async {
    final explicitPath =
        modelPath?.trim();

    final explicitId =
        modelId?.trim();

    if (explicitPath != null &&
        explicitPath.isNotEmpty &&
        explicitId != null &&
        explicitId.isNotEmpty) {
      return null;
    }

    final result =
        await _localAiRepository
            .getSelectedModel();

    return result.fold(
      (failure) {
        logEvent(
          _tag,
          '[MODEL_RESOLVE_FAIL] '
          '${failure.message}',
        );

        return null;
      },
      (model) {
        if (model == null) {
          logEvent(
            _tag,
            '[MODEL_RESOLVE_FAIL] '
            'no selected local model',
          );

          return null;
        }

        return model;
      },
    );
  }

  Future<({
    String? modelId,
    String? modelPath,
    String? error
  })> _resolveInferenceModel({
    String? modelPath,
    String? modelId,
  }) async {
    final explicitPath =
        modelPath?.trim();

    final explicitId =
        modelId?.trim();

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

    final selectedModel =
        await _resolveSelectedModel(
      modelPath: modelPath,
      modelId: modelId,
    );

    if (selectedModel == null) {
      return (
        modelId: null,
        modelPath: null,
        error:
            'Nessun modello locale selezionato.',
      );
    }

    final selectedPath =
        selectedModel.localPath?.trim();

    if (selectedPath == null ||
        selectedPath.isEmpty) {
      logEvent(
        _tag,
        '[MODEL_RESOLVE_FAIL] '
        'selected model has no local path '
        'modelId='
        '${selectedModel.effectiveRuntimeModelId}',
      );

      return (
        modelId:
            selectedModel
                .effectiveRuntimeModelId,
        modelPath: null,
        error:
            'Il modello locale selezionato '
            'non ha un percorso locale valido.',
      );
    }

    return (
      modelId:
          selectedModel.effectiveRuntimeModelId,
      modelPath: selectedPath,
      error: null,
    );
  }

  Future<void> _runLoop({
    required CancellationToken token,
    required String? modelPath,
    required String? modelId,
    required String? systemPrompt,
    required Future<void> Function(String text)? onUserTranscript,
    required Future<void> Function(String text)? onAssistantTranscript,
    required void Function(
      String text,
      bool isFinal,
    )? onSubtitle,
    required void Function(
      String error,
    )? onError,
    required void Function(LiveVoicePhase phase) notifyPhase,
  }) async {
    if (_disposed ||
        token.isCancelled) {
      return;
    }

    // -----------------------------------------------------------------------
    // 1. STT
    // -----------------------------------------------------------------------

    final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    if (android) {
      // In Live, ASR is deliberately unloaded before local inference.
      // Re-create it at the start of the next spoken turn, not while the
      // previous local model or PCM output is still running.
      final status = await _engine.initialize();
      if (_disposed || token.isCancelled || _stopRequested) return;
      if (!status.readyForInput) {
        logEvent(_tag, '[LIVE_ASR_REINIT_FAIL] android=true');
        onError?.call('Riconoscimento vocale non disponibile. Verifica i modelli vocali.');
        return;
      }
    }

    final sttCompleter =
        Completer<String>();
    token.onCancel(() {
      if (!sttCompleter.isCompleted) sttCompleter.complete('');
    });

    void completeStt(
      String text,
    ) {
      if (sttCompleter.isCompleted) {
        return;
      }

      final normalized =
          text.trim();

      if (normalized.isEmpty) {
        return;
      }

      sttCompleter.complete(
        normalized,
      );
    }

    try {
      notifyPhase(LiveVoicePhase.listening);
      logEvent(
        _tag,
        '[STT_START] '
        'locale='
        '${AppConstants.sttDefaultLocaleId}',
      );

      await _engine.startListening(
        localeId:
            AppConstants.sttDefaultLocaleId,
        onResult: (
          text,
          isFinal,
        ) {
          if (_disposed ||
              token.isCancelled ||
              _stopRequested) {
            return;
          }

          final normalized =
              text.trim();

          if (normalized.isEmpty) {
            return;
          }

          logEvent(
            _tag,
            '[STT_RESULT] '
            'final=$isFinal '
            'chars=${normalized.length}',
          );

          onSubtitle?.call(
            normalized,
            isFinal,
          );

          if (isFinal) {
            completeStt(
              normalized,
            );
          }
        },
      );
      if (!_engine.isListening && !token.isCancelled && !_stopRequested) {
        const message = 'Microfono o riconoscimento vocale non disponibile.';
        logEvent(_tag, '[STT_NOT_LISTENING]');
        onError?.call(message);
        return;
      }
    } catch (error) {
      if (!token.isCancelled &&
          !_stopRequested) {
        final message =
            'Voice input failed: $error';

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
      spokenText =
          await sttCompleter.future
              .timeout(
        _sttTimeout,
        onTimeout: () => '',
      );
    } catch (error) {
      if (!token.isCancelled &&
          !_stopRequested) {
        final message =
            'Voice input timeout: $error';

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
      } catch (_) {}
    }

    if (_disposed ||
        token.isCancelled ||
        _stopRequested) {
      return;
    }

    spokenText =
        spokenText.trim();

    if (spokenText.isEmpty) {
      logEvent(
        _tag,
        '[STT_EMPTY]',
      );

      return;
    }

    logEvent(
      _tag,
      '[STT_FINAL_TEXT] '
      'chars=${spokenText.length}',
    );

    notifyPhase(LiveVoicePhase.resolvingModel);
    if (android) {
      // Do not run Android local LLM and the large native Sherpa recognizer
      // together on low-RAM devices. Microphone and ASR stream are already
      // stopped before native ASR ownership is released.
      final recognizer = _engine;
      if (recognizer is! VoiceRecognitionMemoryReclaimer) {
        logEvent(_tag, '[LIVE_ASR_MEMORY_HANDOFF_UNAVAILABLE]');
        onError?.call('Live Android: rilascio memoria vocale non disponibile.');
        return;
      }
      final released = await (recognizer as VoiceRecognitionMemoryReclaimer)
          .releaseRecognitionMemoryForInference();
      if (_disposed || token.isCancelled || _stopRequested) return;
      logEvent(_tag, '[LIVE_ASR_MEMORY_HANDOFF] requested=true released=$released');
      if (!released) {
        onError?.call('Memoria riconoscimento vocale non liberata. Live interrotto per sicurezza.');
        return;
      }
    }

    // Persist the recognized user turn in this same local chat before
    // inference or Kokoro playback starts. No second LLM run occurs.
    if (onUserTranscript != null) {
      try {
        await onUserTranscript(spokenText);
        logEvent(_tag, '[LIVE_TRANSCRIPT_SAVED] role=user');
      } catch (error) {
        logEvent(_tag, '[LIVE_TRANSCRIPT_SAVE_FAILED] role=user');
        onError?.call('Impossibile salvare la domanda Live nella chat.');
        return;
      }
      if (_disposed || token.isCancelled || _stopRequested) return;
    }

    // Start after the user's speech is fully recognized. These metrics never
    // contain the transcript, and TTS_REQUEST does not imply audible output.
    final latency = LiveVoiceLatency();

    // -----------------------------------------------------------------------
    // 2. RESOLVE ACTIVE LOCAL MODEL
    // -----------------------------------------------------------------------

    final resolvedModel =
        await _resolveInferenceModel(
      modelPath: modelPath,
      modelId: modelId,
    );

    if (_disposed ||
        token.isCancelled ||
        _stopRequested) {
      return;
    }

    if (resolvedModel.error != null) {
      final message =
          resolvedModel.error!;

      logEvent(
        _tag,
        '[MODEL_RESOLVE_ERROR] $message',
      );

      onError?.call(message);

      return;
    }

    final resolvedModelId =
        resolvedModel.modelId;

    final resolvedModelPath =
        resolvedModel.modelPath;

    if (resolvedModelId == null ||
        resolvedModelId.isEmpty ||
        resolvedModelPath == null ||
        resolvedModelPath.isEmpty) {
      const message =
          'Percorso del modello locale mancante.';

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

    final request =
        InferenceRequest(
      sessionId:
          'voice_loop_'
          '${DateTime.now().microsecondsSinceEpoch}',
      prompt: spokenText,
      systemPrompt: systemPrompt?.trim().isNotEmpty == true
          ? systemPrompt
          : _defaultLiveItalianSystemPrompt,
      isOffline: true,
      // Constrain Android Live PCM and inference peak while the 8 GB
      // device's native allocation pressure is being investigated.
      maxTokens: android ? 128 : 256,
      temperature: 0.7,
      modelId: resolvedModelId,
      modelPath: resolvedModelPath,
    );

    Stream<dynamic>
        inferenceStream;

    try {
      notifyPhase(LiveVoicePhase.thinking);
      logEvent(
        _tag,
        '[INFERENCE_START] '
        'modelId=$resolvedModelId',
      );

      inferenceStream =
          _runtimeProvider
              .streamInference(
        request: request,
        cancellationToken:
            token,
      );
    } catch (error) {
      if (!token.isCancelled &&
          !_stopRequested) {
        final message =
            'Voice inference failed '
            'to start: $error';

        logEvent(
          _tag,
          '[INFERENCE_START_ERROR] '
          '$message',
        );

        onError?.call(message);
      }

      return;
    }

    // -----------------------------------------------------------------------
    // 4. TOKEN -> TTS
    // -----------------------------------------------------------------------

    final tokenBuffer =
        StringBuffer();
    final responseAssembler = LiveResponseTextAssembler();
    var inferenceFailed = false;

    final sentenceBoundaryPattern =
        RegExp(r'[.!?\n]');

    // Ordered playback continues independently of token ingestion.
    // At most two queued speech operations are kept pending.
    Future<void> playbackTail = Future<void>.value();
    final pendingPlayback = <Future<void>>[];
    bool playbackFailed = false;

    Future<void> queueSpeech(String text) async {
      if (pendingPlayback.length >= 2) {
        await pendingPlayback.removeAt(0);
      }
      if (_disposed || token.isCancelled || _stopRequested ||
          playbackFailed) {
        return;
      }
      playbackTail = playbackTail.then((_) async {
        if (_disposed || token.isCancelled || _stopRequested ||
            playbackFailed) {
          return;
        }
        try {
          notifyPhase(LiveVoicePhase.synthesizing);
          await _engine.speak(text);
        } catch (error) {
          playbackFailed = true;
          if (!token.isCancelled && !_stopRequested && !_disposed) {
            final message = 'Voice output failed: $error';
            logEvent(_tag, '[TTS_ERROR] $message');
            onError?.call(message);
          }
        }
      });
      pendingPlayback.add(playbackTail);
    }


    Future<void> awaitAudibleOutput() async {
      notifyPhase(LiveVoicePhase.playing);
      // speak() can finish while PCM is still playing through the native
      // output sink. Opening ASR immediately then causes acoustic feedback.
      final drained = await waitForLivePlaybackDrain(
        isPlaying: () async {
          final voice = _engine;
          if (voice is ReadAloudVoiceEngine) {
            try {
              final status = await (voice as ReadAloudVoiceEngine)
                  .refreshReadAloud();
              // On desktop the shared engine implements ReadAloudVoiceEngine
              // but has no Android read-aloud sink. Never ignore its actual
              // PCM player queue in that case.
              return status.playing || voice.isSpeaking;
            } catch (_) {
              // Native transport status is best-effort; keep a quiet tail.
            }
          }
          return voice.isSpeaking;
        },
        isCancelled: () => _disposed || token.isCancelled || _stopRequested,
      );
      if (!drained && !_disposed && !token.isCancelled && !_stopRequested) {
        logEvent(_tag, '[LIVE_OUTPUT_DRAIN_TIMEOUT]');
        onError?.call('Riproduzione vocale ancora attiva. Riascolto sospeso per evitare eco.');
      } else if (drained) {
        logEvent(_tag, '[LIVE_OUTPUT_DRAINED]');
      }
    }

    // Live streaming can call speak() for multiple punctuation chunks. Those
    // chunks must share ONE native PCM timeline; repeated prepare() deletes
    // the previous audio file and truncates audible speech on Android.
    final speechSequence = _engine is LiveSpeechSequenceEngine
        ? _engine as LiveSpeechSequenceEngine
        : null;
    speechSequence?.beginLiveSpeechSequence();
    var speechSequenceOpen = speechSequence != null;

    Future<void> closeSpeechSequence(bool completed) async {
      if (!speechSequenceOpen) return;
      speechSequenceOpen = false;
      try {
        await speechSequence!.endLiveSpeechSequence(completed: completed);
      } catch (_) {
        // A native finish error must not leave the playback service alive.
        try {
          await _engine.stopSpeaking();
        } catch (_) {
          logEvent(_tag, '[LIVE_PCM_SEQUENCE_STOP_WARN]');
        }
        rethrow;
      }
    }

    try {
    await for (
      final response in inferenceStream
    ) {
      if (_disposed ||
          token.isCancelled ||
          _stopRequested) {
        break;
      }

      if (response.isError) {
        inferenceFailed = true;
        final message =
            response.errorMessage ??
                'Voice inference error';

        logEvent(
          _tag,
          '[INFERENCE_ERROR] '
          '$message',
        );

        onError?.call(message);

        break;
      }

      // Final chunks contain the FULL canonical reply; all earlier token
      // chunks are deltas. Forward only genuinely new text to chat and TTS.
      final chunk = responseAssembler.add(
        text: response.text,
        isFinal: response.isFinal,
      );
      if (response.isFinal && responseAssembler.finalMismatch) {
        logEvent(_tag, '[LIVE_FINAL_TEXT_MISMATCH] deduped=true');
      }
      if (chunk.isEmpty) {
        continue;
      }

      final firstTokenMs = latency.recordFirstTokenMs();
      if (firstTokenMs != null) {
        logEvent(_tag, '[VOICE_LATENCY] first_token_ms=$firstTokenMs');
      }

      tokenBuffer.write(
        chunk,
      );
      final currentText =
          tokenBuffer.toString();

      onSubtitle?.call(
        currentText,
        response.isFinal,
      );

      final shouldFlush =
          response.isFinal ||
          sentenceBoundaryPattern
              .hasMatch(chunk);

      if (!shouldFlush) {
        continue;
      }

      final speakChunk =
          tokenBuffer
              .toString()
              .trim();

      tokenBuffer.clear();

      if (speakChunk.isEmpty) {
        continue;
      }

      if (_disposed ||
          token.isCancelled ||
          _stopRequested) {
        break;
      }

      logEvent(
        _tag,
        '[TTS_CHUNK] '
        'chars=${speakChunk.length} '
        'final=${response.isFinal}',
      );

      final firstTtsMs = latency.recordFirstTtsRequestMs();
      if (firstTtsMs != null) {
        logEvent(_tag, '[VOICE_LATENCY] first_tts_request_ms=$firstTtsMs');
      }

      await queueSpeech(speakChunk);
      if (playbackFailed) break;
    }

    // Persist completed output before waiting for native playback drain.
    // A later PCM failure must not erase a successfully generated reply.
    final completedResponseText = responseAssembler.text.trim();
    if (!inferenceFailed &&
        completedResponseText.isNotEmpty &&
        onAssistantTranscript != null) {
      try {
        await onAssistantTranscript(completedResponseText);
        logEvent(_tag, '[LIVE_TRANSCRIPT_SAVED] role=assistant');
      } catch (_) {
        logEvent(_tag, '[LIVE_TRANSCRIPT_SAVE_FAILED] role=assistant');
        onError?.call('Impossibile salvare la risposta Live nella chat.');
        return;
      }
    }

    // -----------------------------------------------------------------------
    // 5. TRAILING TTS
    // -----------------------------------------------------------------------

    if (_disposed ||
        token.isCancelled ||
        _stopRequested) {
      return;
    }

    final trailing =
        tokenBuffer
            .toString()
            .trim();

    if (trailing.isEmpty) {
      await Future.wait(pendingPlayback);
      if (!_disposed && !token.isCancelled && !_stopRequested &&
          !playbackFailed && !inferenceFailed) {
        await closeSpeechSequence(true);
        await awaitAudibleOutput();
      }
      return;
    }

    logEvent(
      _tag,
      '[TTS_TRAILING_CHUNK] '
      'chars=${trailing.length}',
    );

    final firstTtsMs = latency.recordFirstTtsRequestMs();
    if (firstTtsMs != null) {
      logEvent(_tag, '[VOICE_LATENCY] first_tts_request_ms=$firstTtsMs');
    }

    await queueSpeech(trailing);
    await Future.wait(pendingPlayback);
    if (!_disposed && !token.isCancelled && !_stopRequested &&
        !playbackFailed && !inferenceFailed) {
      await closeSpeechSequence(true);
      await awaitAudibleOutput();
    }
    } finally {
      if (speechSequenceOpen) {
        // Prevent queued speech callbacks from starting AFTER a failed turn
        // has stopped the PCM sink, even if the inference stream failed.
        playbackFailed = true;
        // A failed, cancelled or interrupted response may still have an
        // in-flight TTS worker. Invalidate it before stopping the PCM stream.
        try {
          await _engine.stopSpeaking();
        } catch (_) {
          logEvent(_tag, '[LIVE_PCM_SEQUENCE_STOP_WARN]');
        }
        await closeSpeechSequence(false);
      }
    }
  }
}

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'package:ai_orchestrator/core/config/app/app_constants.dart';

/// Service that wraps [SpeechToText] and [FlutterTts] to provide a unified
/// voice-interaction interface for the AI Orchestrator.
class SpeechService {
  SpeechService({SpeechToText? stt, FlutterTts? tts})
      : _stt = stt ?? SpeechToText(),
        _tts = tts ?? FlutterTts();

  final SpeechToText _stt;
  final FlutterTts _tts;

  bool _sttInitialised = false;
  bool _isSpeaking = false;

  // ── Initialisation ──────────────────────────────────────────────────────────

  /// Requests microphone permission and initialises the STT engine.
  ///
  /// Returns `true` on success.
  Future<bool> initialise() async {
    if (!kIsWeb) {
      final status = await Permission.microphone.request();
      if (status.isDenied || status.isPermanentlyDenied) return false;
    }

    _sttInitialised = await _stt.initialize(
      onError: (e) => debugPrint('STT error: $e'),
    );

    await _tts.setLanguage(AppConstants.ttsDefaultLocale);
    await _tts.setSpeechRate(AppConstants.ttsSpeechRate);
    await _tts.setVolume(AppConstants.ttsVolume);
    await _tts.setPitch(AppConstants.ttsPitch);
    _tts.setCompletionHandler(() => _isSpeaking = false);

    return _sttInitialised;
  }

  // ── Speech-to-Text ──────────────────────────────────────────────────────────

  /// Whether STT is currently listening.
  bool get isListening => _stt.isListening;

  /// Starts listening and calls [onResult] with each recognised partial /
  /// final transcription.
  Future<void> startListening({
    required void Function(String text, bool isFinal) onResult,
    String localeId = AppConstants.sttDefaultLocaleId,
  }) async {
    if (!_sttInitialised) {
      final ok = await initialise();
      if (!ok) return;
    }

    await _stt.listen(
      onResult: (SpeechRecognitionResult result) {
        onResult(result.recognizedWords, result.finalResult);
      },
      localeId: localeId,
      listenOptions: SpeechListenOptions(
        partialResults: true,
        listenMode: ListenMode.confirmation,
      ),
    );
  }

  /// Stops the current STT listening session.
  Future<void> stopListening() async {
    await _stt.stop();
  }

  // ── Text-to-Speech ──────────────────────────────────────────────────────────

  /// Speaks [text] aloud using the device TTS engine.
  Future<void> speak(String text) async {
    await _tts.stop();
    _isSpeaking = true;
    await _tts.speak(text);
  }

  /// Stops any ongoing speech synthesis.
  Future<void> stopSpeaking() async {
    await _tts.stop();
    _isSpeaking = false;
  }

  /// Returns true if TTS is currently speaking.
  bool get isSpeaking => _isSpeaking;

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  Future<void> dispose() async {
    await _stt.cancel();
    await _tts.stop();
  }
}

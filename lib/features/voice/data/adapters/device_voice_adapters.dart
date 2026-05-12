import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/features/voice/data/adapters/voice_asr_adapter.dart';
import 'package:ai_orchestrator/features/voice/data/adapters/voice_tts_adapter.dart';

class DeviceSpeechToTextAdapter implements VoiceAsrAdapter {
  DeviceSpeechToTextAdapter({SpeechToText? stt}) : _stt = stt ?? SpeechToText();

  final SpeechToText _stt;
  bool _initialized = false;

  @override
  Future<bool> initialize() async {
    _initialized = await _stt.initialize(
      onError: (e) => debugPrint('Device STT error: $e'),
    );
    return _initialized;
  }

  @override
  bool get isListening => _stt.isListening;

  @override
  Future<void> startListening({
    required void Function(String text, bool isFinal) onResult,
    String localeId = AppConstants.sttDefaultLocaleId,
  }) async {
    if (!_initialized) {
      final ok = await initialize();
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

  @override
  Future<void> stopListening() => _stt.stop();

  @override
  Future<void> dispose() => _stt.cancel();
}

class DeviceFlutterTtsAdapter implements VoiceTtsAdapter {
  DeviceFlutterTtsAdapter({FlutterTts? tts}) : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;
  bool _initialized = false;
  bool _isSpeaking = false;

  @override
  Future<bool> initialize() async {
    await _tts.setLanguage(AppConstants.ttsDefaultLocale);
    await _tts.setSpeechRate(AppConstants.ttsSpeechRate);
    await _tts.setVolume(AppConstants.ttsVolume);
    await _tts.setPitch(AppConstants.ttsPitch);
    _tts.setCompletionHandler(() => _isSpeaking = false);
    _initialized = true;
    return true;
  }

  @override
  bool get isSpeaking => _isSpeaking;

  @override
  Future<void> speak(String text) async {
    if (!_initialized) {
      await initialize();
    }
    await _tts.stop();
    _isSpeaking = true;
    await _tts.speak(text);
  }

  @override
  Future<void> stopSpeaking() async {
    await _tts.stop();
    _isSpeaking = false;
  }

  @override
  Future<void> dispose() => _tts.stop();
}

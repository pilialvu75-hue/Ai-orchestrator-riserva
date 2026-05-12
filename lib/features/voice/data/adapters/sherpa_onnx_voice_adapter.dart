import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/features/voice/data/adapters/voice_asr_adapter.dart';
import 'package:ai_orchestrator/features/voice/data/adapters/voice_tts_adapter.dart';

/// Android/native bridge for Sherpa-ONNX offline ASR + TTS.
///
/// The implementation is intentionally isolated behind channels so that
/// orchestrator/inference layers remain platform-agnostic and replaceable.
class SherpaOnnxVoiceAdapter implements VoiceAsrAdapter, VoiceTtsAdapter {
  SherpaOnnxVoiceAdapter({
    MethodChannel? methodChannel,
    EventChannel? asrEventChannel,
  })  : _methodChannel =
            methodChannel ?? const MethodChannel(AppConstants.sherpaVoiceMethodChannel),
        _asrEventChannel = asrEventChannel ??
            const EventChannel(AppConstants.sherpaAsrEventChannel);

  final MethodChannel _methodChannel;
  final EventChannel _asrEventChannel;

  StreamSubscription<dynamic>? _asrSubscription;
  bool _isListening = false;
  bool _isSpeaking = false;
  bool _initialized = false;

  @override
  Future<bool> initialize() async {
    if (_initialized) return true;
    try {
      final ok = await _methodChannel.invokeMethod<bool>('initializeSherpaOnnx');
      _initialized = ok ?? false;
      return _initialized;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      debugPrint('Sherpa init error: ${e.message}');
      return false;
    }
  }

  @override
  bool get isListening => _isListening;

  @override
  Future<void> startListening({
    required void Function(String text, bool isFinal) onResult,
    String localeId = AppConstants.sttDefaultLocaleId,
  }) async {
    if (!_initialized && !await initialize()) return;

    await _asrSubscription?.cancel();
    _asrSubscription = _asrEventChannel.receiveBroadcastStream().listen(
      (dynamic event) {
        if (event is! Map) return;
        final map = Map<String, dynamic>.from(event as Map<dynamic, dynamic>);
        final text = (map['text'] as String? ?? '').trim();
        final isFinal = map['isFinal'] == true;
        if (text.isNotEmpty) {
          onResult(text, isFinal);
        }
      },
      onError: (Object error) {
        debugPrint('Sherpa ASR stream error: $error');
      },
    );

    try {
      await _methodChannel.invokeMethod<void>('startAsr', <String, dynamic>{
        'localeId': localeId,
      });
      _isListening = true;
    } on PlatformException catch (e) {
      debugPrint('Sherpa startAsr error: ${e.message}');
      _isListening = false;
    }
  }

  @override
  Future<void> stopListening() async {
    try {
      await _methodChannel.invokeMethod<void>('stopAsr');
    } on MissingPluginException {
      // Ignore on unsupported platforms.
    } on PlatformException catch (e) {
      debugPrint('Sherpa stopAsr error: ${e.message}');
    }
    _isListening = false;
    await _asrSubscription?.cancel();
    _asrSubscription = null;
  }

  @override
  bool get isSpeaking => _isSpeaking;

  @override
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    if (!_initialized && !await initialize()) return;
    try {
      await _methodChannel.invokeMethod<void>('speakTts', <String, dynamic>{
        'text': text,
      });
      _isSpeaking = true;
    } on MissingPluginException {
      _isSpeaking = false;
    } on PlatformException catch (e) {
      debugPrint('Sherpa speakTts error: ${e.message}');
      _isSpeaking = false;
    }
  }

  @override
  Future<void> stopSpeaking() async {
    try {
      await _methodChannel.invokeMethod<void>('stopTts');
    } on MissingPluginException {
      // Ignore on unsupported platforms.
    } on PlatformException catch (e) {
      debugPrint('Sherpa stopTts error: ${e.message}');
    }
    _isSpeaking = false;
  }

  @override
  Future<void> dispose() async {
    await stopListening();
    await stopSpeaking();
  }
}

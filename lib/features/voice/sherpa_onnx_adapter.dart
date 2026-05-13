import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/voice/voice_engine.dart';

class SherpaOnnxAdapter implements VoiceEngine {
  SherpaOnnxAdapter({
    MethodChannel? methodChannel,
    EventChannel? asrEventChannel,
  })  : _methodChannel =
            methodChannel ?? const MethodChannel(AppConstants.sherpaVoiceMethodChannel),
        _asrEventChannel = asrEventChannel ??
            const EventChannel(AppConstants.sherpaAsrEventChannel);

  final MethodChannel _methodChannel;
  final EventChannel _asrEventChannel;

  StreamSubscription<dynamic>? _asrSubscription;
  VoiceEngineStatus _status = VoiceEngineStatus.unsupported();
  bool _isListening = false;
  bool _isSpeaking = false;

  @override
  bool get isListening => _isListening;

  @override
  bool get isSpeaking => _isSpeaking;

  @override
  Future<VoiceEngineStatus> inspect() async {
    try {
      final response = await _methodChannel.invokeMethod<dynamic>('getSherpaStatus');
      _status = _parseStatus(response);
    } on MissingPluginException {
      _status = VoiceEngineStatus.unsupported(
        details: 'Sherpa-ONNX platform channel is unavailable.',
      );
    } on PlatformException catch (error) {
      _status = VoiceEngineStatus.unsupported(details: error.message);
    }
    return _status;
  }

  @override
  Future<VoiceEngineStatus> initialize() async {
    try {
      final response =
          await _methodChannel.invokeMethod<dynamic>('initializeSherpaOnnx');
      _status = _parseStatus(response);
    } on MissingPluginException {
      _status = VoiceEngineStatus.unsupported(
        details: 'Sherpa-ONNX platform channel is unavailable.',
      );
    } on PlatformException catch (error) {
      debugPrint('Sherpa init error: ${error.message}');
      _status = VoiceEngineStatus.unsupported(details: error.message);
    }
    return _status;
  }

  @override
  Future<void> startListening({
    required VoiceRecognitionResultCallback onResult,
    String localeId = AppConstants.sttDefaultLocaleId,
  }) async {
    if (!_status.initialized) {
      await initialize();
    }
    if (!_status.readyForInput) return;

    await _asrSubscription?.cancel();
    _asrSubscription = _asrEventChannel.receiveBroadcastStream().listen(
      (dynamic event) {
        if (event is! Map<dynamic, dynamic>) return;
        final text = (event['text'] as String? ?? '').trim();
        final isFinal = event['isFinal'] == true;
        if (text.isNotEmpty) {
          onResult(text, isFinal);
        }
      },
      onError: (Object error) {
        debugPrint('Sherpa ASR stream error: $error');
        _isListening = false;
      },
    );

    try {
      await _methodChannel.invokeMethod<void>('startAsr', <String, dynamic>{
        'localeId': localeId,
      });
      _isListening = true;
    } on MissingPluginException {
      _isListening = false;
    } on PlatformException catch (error) {
      debugPrint('Sherpa startAsr error: ${error.message}');
      _isListening = false;
    }
  }

  @override
  Future<void> stopListening() async {
    try {
      await _methodChannel.invokeMethod<void>('stopAsr');
    } on MissingPluginException {
      // Ignore on unsupported platforms.
    } on PlatformException catch (error) {
      debugPrint('Sherpa stopAsr error: ${error.message}');
    }
    _isListening = false;
    await _asrSubscription?.cancel();
    _asrSubscription = null;
  }

  @override
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    if (!_status.initialized) {
      await initialize();
    }
    if (!_status.readyForOutput) return;

    try {
      await _methodChannel.invokeMethod<void>('speakTts', <String, dynamic>{
        'text': text,
      });
      _isSpeaking = true;
    } on MissingPluginException {
      _isSpeaking = false;
    } on PlatformException catch (error) {
      debugPrint('Sherpa speakTts error: ${error.message}');
      _isSpeaking = false;
    }
  }

  @override
  Future<void> stopSpeaking() async {
    try {
      await _methodChannel.invokeMethod<void>('stopTts');
    } on MissingPluginException {
      // Ignore on unsupported platforms.
    } on PlatformException catch (error) {
      debugPrint('Sherpa stopTts error: ${error.message}');
    }
    _isSpeaking = false;
  }

  @override
  Future<void> dispose() async {
    await stopListening();
    await stopSpeaking();
  }

  VoiceEngineStatus _parseStatus(dynamic response) {
    if (response is Map) {
      return VoiceEngineStatus.fromMap(
        Map<Object?, Object?>.from(response as Map<dynamic, dynamic>),
      );
    }
    if (response is bool) {
      final supported = switch (defaultTargetPlatform) {
        TargetPlatform.android ||
        TargetPlatform.windows ||
        TargetPlatform.linux ||
        TargetPlatform.macOS =>
          true,
        _ => false,
      };
      return VoiceEngineStatus(
        engineId: sherpaOnnxEngineId,
        supportedPlatform: supported,
        nativeLibrariesLoaded: response,
        microphonePermissionGranted: response,
        audioSessionReady: response,
        speakerOutputReady: response,
        initialized: response,
        offlineAsrAvailable: response,
        offlineTtsAvailable: response,
      );
    }
    return VoiceEngineStatus.unsupported(
      details: 'Invalid Sherpa-ONNX status response: ${response.runtimeType}',
    );
  }
}

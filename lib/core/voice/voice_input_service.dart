import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/voice/voice_engine.dart';
import 'package:ai_orchestrator/core/voice/voice_text_normalizer.dart';

class VoiceInputService {
  VoiceInputService({
    required VoiceEngine engine,
    VoiceTextNormalizer normalizer = const VoiceTextNormalizer(),
  })  : _engine = engine,
        _normalizer = normalizer;

  final VoiceEngine _engine;
  final VoiceTextNormalizer _normalizer;

  VoiceEngineStatus? _lastStatus;

  VoiceEngineStatus? get lastStatus => _lastStatus;

  bool get isListening => _engine.isListening;

  Future<bool> initialize() async {
    final requiresRuntimeMicPermission = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS);
    if (requiresRuntimeMicPermission) {
      final permission = await Permission.microphone.request();
      if (!permission.isGranted) {
        _lastStatus = const VoiceEngineStatus(
          engineId: 'sherpa-onnx',
          supportedPlatform: true,
          nativeLibrariesLoaded: false,
          microphonePermissionGranted: false,
          audioSessionReady: false,
          speakerOutputReady: false,
          initialized: false,
          offlineAsrAvailable: false,
          offlineTtsAvailable: false,
          details: 'Microphone permission denied.',
        );
        return false;
      }
    }

    _lastStatus = await _engine.initialize();
    return _lastStatus?.readyForInput == true;
  }

  Future<void> startListening({
    required VoiceRecognitionResultCallback onResult,
    String localeId = AppConstants.sttDefaultLocaleId,
  }) async {
    final ready = await initialize();
    if (!ready) return;

    await _engine.startListening(
      localeId: localeId,
      onResult: (text, isFinal) {
        final normalized = _normalizer.normalizeAsr(text);
        if (normalized.isNotEmpty) {
          onResult(normalized, isFinal);
        }
      },
    );
  }

  Future<void> stopListening() => _engine.stopListening();
}

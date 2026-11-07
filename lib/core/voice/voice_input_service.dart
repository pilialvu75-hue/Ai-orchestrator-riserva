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
  Future<void>? _stopInFlight;
  Future<bool>? _reclamationInFlight;

  VoiceEngineStatus? get lastStatus => _lastStatus;

  bool get isListening => _engine.isListening;

  Future<bool> initialize() async {
    if (_lastStatus?.readyForInput == true) {
      return true;
    }

    final requiresRuntimeMicPermission = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS);
    if (requiresRuntimeMicPermission) {
      final permission = await Permission.microphone.request();
      if (!permission.isGranted) {
        _lastStatus = const VoiceEngineStatus(
          engineId: sherpaOnnxEngineId,
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
    // Never reopen Sherpa while the previous native stream is being closed
    // or its recognizer is being released for an inference handoff.
    final reclaiming = _reclamationInFlight;
    if (reclaiming != null) await reclaiming;
    final stopping = _stopInFlight;
    if (stopping != null) await stopping;
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

  /// Coalesce Stop from native final callback, Send and route disposal.
  /// Overlapping native stop/free requests can invalidate the same stream.
  Future<void> stopListening() {
    final pending = _stopInFlight;
    if (pending != null) return pending;
    late Future<void> work;
    work = Future<void>.sync(_engine.stopListening).whenComplete(() {
      if (identical(_stopInFlight, work)) _stopInFlight = null;
    });
    _stopInFlight = work;
    return work;
  }

  /// Optional release after a short dictation, never for continuous Live.
  /// Reinitialization is mandatory before the next chat microphone tap.
  Future<bool> releaseRecognitionMemoryForInference() {
    final pending = _reclamationInFlight;
    if (pending != null) return pending;
    late Future<bool> work;
    work = _releaseAfterStop().whenComplete(() {
      if (identical(_reclamationInFlight, work)) {
        _reclamationInFlight = null;
      }
    });
    _reclamationInFlight = work;
    return work;
  }

  Future<bool> _releaseAfterStop() async {
    await stopListening();
    final engine = _engine;
    if (engine is! VoiceRecognitionMemoryReclaimer) return false;
    // Even if native free reports a warning, the recognizer handle may be
    // invalidated. Force a fresh initialize on the next microphone tap.
    _lastStatus = null;
    return (engine as VoiceRecognitionMemoryReclaimer)
        .releaseRecognitionMemoryForInference();
  }
}

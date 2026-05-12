import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/features/voice/data/adapters/voice_asr_adapter.dart';
import 'package:ai_orchestrator/features/voice/data/adapters/voice_tts_adapter.dart';
import 'package:ai_orchestrator/features/voice/data/normalization/voice_text_normalizer.dart';

/// Modular voice pipeline facade:
/// mic -> ASR -> text normalization -> orchestrator input
/// and orchestrator output -> TTS -> speaker.
class SpeechService {
  SpeechService({
    required VoiceAsrAdapter primaryAsr,
    required VoiceAsrAdapter fallbackAsr,
    required VoiceTtsAdapter primaryTts,
    required VoiceTtsAdapter fallbackTts,
    bool sharedAsrAdapter = false,
    bool sharedTtsAdapter = false,
    VoiceTextNormalizer normalizer = const VoiceTextNormalizer(),
  })  : _primaryAsr = primaryAsr,
        _fallbackAsr = fallbackAsr,
        _primaryTts = primaryTts,
        _fallbackTts = fallbackTts,
        _normalizer = normalizer,
        _sharedAsrAdapter = sharedAsrAdapter,
        _sharedTtsAdapter = sharedTtsAdapter;

  final VoiceAsrAdapter _primaryAsr;
  final VoiceAsrAdapter _fallbackAsr;
  final VoiceTtsAdapter _primaryTts;
  final VoiceTtsAdapter _fallbackTts;
  final VoiceTextNormalizer _normalizer;
  final bool _sharedAsrAdapter;
  final bool _sharedTtsAdapter;

  VoiceAsrAdapter? _activeAsr;
  VoiceTtsAdapter? _activeTts;
  bool _initialized = false;

  Future<bool> initialise() async {
    if (_initialized) return true;

    if (!kIsWeb) {
      final status = await Permission.microphone.request();
      if (status.isDenied || status.isPermanentlyDenied) return false;
    }

    final sherpaAsrReady = await _primaryAsr.initialize();
    if (sherpaAsrReady) {
      _activeAsr = _primaryAsr;
    } else {
      final fallbackAsrReady = await _fallbackAsr.initialize();
      if (fallbackAsrReady) {
        _activeAsr = _fallbackAsr;
      }
    }

    final sherpaTtsReady = await _primaryTts.initialize();
    if (sherpaTtsReady) {
      _activeTts = _primaryTts;
    } else {
      final fallbackTtsReady = await _fallbackTts.initialize();
      if (fallbackTtsReady) {
        _activeTts = _fallbackTts;
      }
    }

    _initialized = _activeAsr != null && _activeTts != null;
    return _initialized;
  }

  bool get isListening => _activeAsr?.isListening ?? false;

  bool get isSpeaking => _activeTts?.isSpeaking ?? false;

  Future<void> startListening({
    required void Function(String text, bool isFinal) onResult,
    String localeId = AppConstants.sttDefaultLocaleId,
  }) async {
    if (!_initialized) {
      final ok = await initialise();
      if (!ok) return;
    }

    await _activeAsr?.startListening(
      localeId: localeId,
      onResult: (text, isFinal) {
        final normalized = _normalizer.normalizeAsr(text);
        if (normalized.isNotEmpty) {
          onResult(normalized, isFinal);
        }
      },
    );
  }

  Future<void> stopListening() async {
    await _activeAsr?.stopListening();
  }

  Future<void> speak(String text) async {
    if (!_initialized) {
      final ok = await initialise();
      if (!ok) return;
    }
    final normalized = _normalizer.normalizeForTts(text);
    if (normalized.isEmpty) return;
    await _activeTts?.speak(normalized);
  }

  Future<void> stopSpeaking() async {
    await _activeTts?.stopSpeaking();
  }

  Future<void> dispose() async {
    await _primaryAsr.dispose();
    if (!_sharedAsrAdapter) {
      await _fallbackAsr.dispose();
    }
    await _primaryTts.dispose();
    if (!_sharedTtsAdapter) {
      await _fallbackTts.dispose();
    }
  }
}

import 'package:ai_orchestrator/core/voice/voice_engine.dart';
import 'package:ai_orchestrator/core/voice/voice_text_normalizer.dart';

class VoiceOutputService {
  VoiceOutputService({
    required VoiceEngine engine,
    VoiceTextNormalizer normalizer = const VoiceTextNormalizer(),
  })  : _engine = engine,
        _normalizer = normalizer;

  final VoiceEngine _engine;
  final VoiceTextNormalizer _normalizer;

  VoiceEngineStatus? _lastStatus;

  VoiceEngineStatus? get lastStatus => _lastStatus;

  bool get isSpeaking => _engine.isSpeaking;

  Future<bool> initialize() async {
    if (_lastStatus?.initialized == true) {
      return true;
    }

    _lastStatus = await _engine.initialize();

    return _lastStatus?.initialized == true;
  }

  Future<void> speak(String text) async {
    final normalized = _normalizer.normalizeForTts(text);

    if (normalized.isEmpty) {
      return;
    }

    /*
     * TTS is intentionally lazy.
     *
     * VoiceEngine.initialize() initializes the shared/native voice
     * runtime and STT, but it deliberately does NOT initialize TTS.
     *
     * The concrete VoiceEngine implementation is responsible for
     * creating the TTS engine when speak() is actually requested.
     */
    await _engine.speak(normalized);

    /*
     * Refresh the cached status after speak().
     *
     * This is important because a lazy TTS initialization may have
     * changed speakerOutputReady/offlineTtsAvailable inside the engine.
     */
    try {
      _lastStatus = await _engine.inspect();
    } catch (_) {
      // The actual speech request has already been delegated to the engine.
      // A status refresh must never make TTS fail.
    }
  }

  Future<void> stopSpeaking() => _engine.stopSpeaking();
}

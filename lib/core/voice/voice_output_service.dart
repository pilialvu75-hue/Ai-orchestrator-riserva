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
    _lastStatus = await _engine.initialize();
    return _lastStatus?.readyForOutput == true;
  }

  Future<void> speak(String text) async {
    final ready = await initialize();
    if (!ready) return;

    final normalized = _normalizer.normalizeForTts(text);
    if (normalized.isEmpty) return;
    await _engine.speak(normalized);
  }

  Future<void> stopSpeaking() => _engine.stopSpeaking();
}

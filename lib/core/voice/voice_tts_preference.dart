import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The preference affects TTS only; ASR and inference routing are untouched.
/// Unknown persisted values fail closed to the established Kokoro engine.
enum TtsBackend { kokoro, androidSystem }

class VoiceTtsPreference {
  static const key = 'voice_tts_backend_v1';
  static const channel = MethodChannel('com.aiorchestrator/system_tts');

  static Future<TtsBackend> read() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return TtsBackend.kokoro;
    }
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(key) == 'androidSystem'
        ? TtsBackend.androidSystem
        : TtsBackend.kokoro;
  }

  static Future<void> save(TtsBackend value) async {
    if (value == TtsBackend.androidSystem && !await hasOfflineVoice()) {
      throw StateError('Nessuna voce Android offline disponibile.');
    }
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(key, value.name)) {
      throw StateError('Impossibile salvare la voce scelta.');
    }
  }

  static Future<Map<String, dynamic>> inspectAndroid() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return <String, dynamic>{'ready': false, 'voices': <dynamic>[]};
    }
    try {
      final data = await channel.invokeMapMethod<String, dynamic>('inspect');
      return Map<String, dynamic>.from(data ?? const {});
    } on PlatformException {
      return <String, dynamic>{'ready': false, 'voices': <dynamic>[]};
    } on MissingPluginException {
      return <String, dynamic>{'ready': false, 'voices': <dynamic>[]};
    }
  }

  static Future<bool> hasOfflineVoice({String? language}) async {
    final data = await inspectAndroid();
    if (data['ready'] != true) return false;
    final voices = data['voices'];
    if (voices is! List) return false;
    return voices.any((dynamic voice) {
      if (voice is! Map) return false;
      final tag = voice['language']?.toString().toLowerCase() ?? '';
      return language == null || tag == language.toLowerCase() ||
          tag.startsWith('${language.toLowerCase()}-');
    });
  }
}

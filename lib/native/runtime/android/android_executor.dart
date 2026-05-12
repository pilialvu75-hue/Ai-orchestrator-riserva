import 'package:android_intent_plus/android_intent.dart';
import 'package:ai_orchestrator/core/orchestrator/execution_engine.dart';

/// Android implementation of [ExecutionEngine].
///
/// Parses the user [input] to extract an app/package name and launches it
/// via [AndroidIntent] using the standard launcher action.
/// Returns a human-readable status string in all cases.
class AndroidExecutor implements ExecutionEngine {
  @override
  Future<String> execute(String input) async {
    final package = _extractPackage(input);
    if (package == null) {
      return 'Nessuna app riconosciuta nel comando: "$input"';
    }

    try {
      final intent = AndroidIntent(
        action: 'android.intent.action.MAIN',
        category: 'android.intent.category.LAUNCHER',
        package: package,
      );
      await intent.launch();
      return 'App avviata: $package';
    } catch (e) {
      return 'Errore durante l\'avvio di $package: $e';
    }
  }

  /// Maps known keywords to Android package names.
  static const Map<String, String> _packageMap = {
    'youtube': 'com.google.android.youtube',
    'maps': 'com.google.android.apps.maps',
    'chrome': 'com.android.chrome',
    'spotify': 'com.spotify.music',
    'whatsapp': 'com.whatsapp',
    'telegram': 'org.telegram.messenger',
    'camera': 'com.android.camera2',
    'impostazioni': 'com.android.settings',
    'settings': 'com.android.settings',
    'telefono': 'com.android.dialer',
    'phone': 'com.android.dialer',
  };

  String? _extractPackage(String input) {
    final lower = input.toLowerCase();
    for (final entry in _packageMap.entries) {
      // Match whole-word occurrences to avoid false positives from substrings.
      final pattern = RegExp(r'\b' + RegExp.escape(entry.key) + r'\b');
      if (pattern.hasMatch(lower)) {
        return entry.value;
      }
    }
    return null;
  }
}

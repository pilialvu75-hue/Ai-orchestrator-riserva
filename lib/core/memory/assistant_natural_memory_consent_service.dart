import 'package:shared_preferences/shared_preferences.dart';

/// Local, device-specific opt-in for staging direct-user name candidates.
///
/// Disabled until the owner actively enables it in Memory review. This flag
/// does not authorize promotion to confirmed memory or Cloud transfer.
class AssistantNaturalMemoryConsentService {
  const AssistantNaturalMemoryConsentService({
    required SharedPreferences preferences,
  }) : _preferences = preferences;

  static const String preferenceKey =
      'assistant.memory.natural_name_candidates.enabled.v1';

  final SharedPreferences _preferences;

  /// Read at send time and again immediately before a queued capture write.
  bool get enabled => _preferences.getBool(preferenceKey) ?? false;

  /// Revocation is effective on future chat turns and queued write checks.
  /// Already-staged proposals remain visible for separate rejection.
  Future<void> setEnabled(bool enabled) async {
    final persisted = await _preferences.setBool(preferenceKey, enabled);
    if (!persisted) {
      throw StateError('Natural memory consent was not saved.');
    }
  }
}

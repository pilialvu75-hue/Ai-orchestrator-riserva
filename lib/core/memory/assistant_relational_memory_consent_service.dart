import 'package:shared_preferences/shared_preferences.dart';

/// Separate opt-in for proposing facts about *other named people* from chat.
///
/// Disabled by default, independent of personal-name/car-color suggestions.
/// It never authorizes confirmation, identity merging or Cloud transfer.
class AssistantRelationalMemoryConsentService {
  const AssistantRelationalMemoryConsentService({
    required SharedPreferences preferences,
  }) : _preferences = preferences;

  static const String preferenceKey =
      'assistant.memory.named_people_chat_candidates.enabled.v1';

  final SharedPreferences _preferences;

  bool get enabled => _preferences.getBool(preferenceKey) ?? false;

  /// Revoking blocks future and queued proposals; it does not approve drafts.
  Future<void> setEnabled(bool enabled) async {
    final stored = await _preferences.setBool(preferenceKey, enabled);
    if (!stored) {
      throw StateError('Relational memory consent was not saved.');
    }
  }
}

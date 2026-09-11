import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_need_queue.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';

/// Versioned persistence for the Researcher need queue.
///
/// Uses the existing app PreferencesService so the reuse subsystem does not
/// introduce a second configuration/storage stack.
final class WorkshopReuseNeedStore {
  const WorkshopReuseNeedStore({
    required PreferencesService preferences,
    this.storageKey = 'workshop_reuse_need_queue_v1',
  }) : _preferences = preferences;

  final PreferencesService _preferences;
  final String storageKey;

  Future<WorkshopReuseNeedQueue> load() async {
    final raw = _preferences.getString(storageKey);
    if (raw == null || raw.trim().isEmpty) {
      return WorkshopReuseNeedQueue();
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return WorkshopReuseNeedQueue();
      return WorkshopReuseNeedQueue.fromJson(
        Map<String, dynamic>.from(decoded),
      );
    } catch (_) {
      return WorkshopReuseNeedQueue();
    }
  }

  Future<void> save(WorkshopReuseNeedQueue queue) async {
    await _preferences.setString(
      storageKey,
      jsonEncode(queue.toJson()),
    );
  }

  Future<void> clear() async {
    await _preferences.remove(storageKey);
  }
}

import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_source_snapshot.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';

/// Preferences-backed descriptor index for reusable source snapshots.
///
/// Only lightweight paths/metadata are stored here. Source contents live in
/// dedicated snapshot directories on disk.
final class WorkshopReuseSourceSnapshotStore {
  WorkshopReuseSourceSnapshotStore({
    required PreferencesService preferences,
  }) : _preferences = preferences;

  static const String storageKey = 'workshop.reuse_source_snapshots.v1';

  final PreferencesService _preferences;

  Future<WorkshopReuseSourceSnapshotIndex> load() async {
    final raw = _preferences.getString(storageKey);
    if (raw == null || raw.trim().isEmpty) {
      return WorkshopReuseSourceSnapshotIndex();
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return WorkshopReuseSourceSnapshotIndex();
      return WorkshopReuseSourceSnapshotIndex.fromJson(
        Map<String, dynamic>.from(decoded),
      );
    } catch (_) {
      return WorkshopReuseSourceSnapshotIndex();
    }
  }

  Future<void> save(WorkshopReuseSourceSnapshotIndex index) async {
    await _preferences.setString(
      storageKey,
      jsonEncode(index.toJson()),
    );
  }

  Future<void> clear() => _preferences.remove(storageKey);
}

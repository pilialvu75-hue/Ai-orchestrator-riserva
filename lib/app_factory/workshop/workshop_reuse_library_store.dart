import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_library.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';

/// Versioned persistence boundary for the Workshop reuse catalog.
///
/// The store intentionally persists only reusable-asset descriptors. Source
/// files and produced artifacts remain owned by their existing storage layers.
final class WorkshopReuseLibraryStore {
  WorkshopReuseLibraryStore({
    required PreferencesService preferences,
  }) : _preferences = preferences;

  static const String storageKey = 'workshop.reuse_library.v1';

  final PreferencesService _preferences;

  Future<WorkshopReuseLibrary> load() async {
    final raw = _preferences.getString(storageKey);
    if (raw == null || raw.trim().isEmpty) {
      return WorkshopReuseLibrary();
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return WorkshopReuseLibrary();
      return WorkshopReuseLibrary.fromJson(
        Map<String, dynamic>.from(decoded),
      );
    } catch (_) {
      return WorkshopReuseLibrary();
    }
  }

  Future<void> save(WorkshopReuseLibrary library) async {
    await _preferences.setString(
      storageKey,
      jsonEncode(library.toJson()),
    );
  }

  Future<void> clear() => _preferences.remove(storageKey);
}

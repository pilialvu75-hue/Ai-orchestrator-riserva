// AppLegalCore — Persistence layer for legal consent.
//
// Reads and writes [LegalState] via the app's existing [PreferencesService]
// so the module stays framework-agnostic and uses no direct SharedPreferences
// imports.

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:ai_orchestrator/core/app_legal/models/legal_state.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';

class LegalStorageService {
  const LegalStorageService(this._preferences);

  final PreferencesService _preferences;

  static const String _storageKey = 'app_legal_state_v1';

  // ── Read ──────────────────────────────────────────────────────────────────

  /// Returns the persisted [LegalState], or [LegalState.initial()] when no
  /// data has been written yet.
  LegalState loadState() {
    final raw = _preferences.getString(_storageKey);
    if (raw == null || raw.isEmpty) {
      return const LegalState.initial();
    }
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return LegalState.fromJson(json);
    } catch (error) {
      debugPrint('[LegalStorage] Failed to parse saved state: $error');
      return const LegalState.initial();
    }
  }

  // ── Write ─────────────────────────────────────────────────────────────────

  /// Persists the given [state] to local storage.
  Future<void> saveState(LegalState state) async {
    try {
      final encoded = jsonEncode(state.toJson());
      await _preferences.setString(_storageKey, encoded);
      debugPrint('[LegalStorage] Saved legal state (v${state.eulaVersion})');
    } catch (error) {
      debugPrint('[LegalStorage] Failed to save state: $error');
    }
  }

  /// Removes any persisted consent (useful for testing / reset scenarios).
  Future<void> clearState() async {
    await _preferences.remove(_storageKey);
    debugPrint('[LegalStorage] Legal state cleared');
  }
}

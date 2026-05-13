// AppLegalCore — EULA business-logic service.
//
// This service is the single source of truth for whether the current user
// session is allowed to proceed.  The [currentEulaVersion] constant must be
// bumped whenever the legal text changes; the system will then require
// re-acceptance from all existing users.

import 'package:flutter/foundation.dart';

import 'package:ai_orchestrator/core/app_legal/models/legal_state.dart';
import 'package:ai_orchestrator/core/app_legal/services/legal_storage_service.dart';

class EulaService {
  EulaService({required LegalStorageService storageService})
      : _storage = storageService;

  final LegalStorageService _storage;

  // ── Version contract ──────────────────────────────────────────────────────
  // Bump this constant whenever the legal text changes.  All users with a
  // saved version lower than this will be presented with the EULA again.
  static const int currentEulaVersion = 1;

  // ── Optional URL overrides (populated by the app at startup if needed) ────
  String? privacyPolicyUrl;
  String? termsOfServiceUrl;

  // ── State ─────────────────────────────────────────────────────────────────

  LegalState _state = const LegalState.initial();

  /// The last loaded / updated [LegalState].
  LegalState get state => _state;

  // ── Initialisation ────────────────────────────────────────────────────────

  /// Must be called once at app startup (before showing any UI).
  Future<void> initialize() async {
    _state = _storage.loadState();
    debugPrint(
      '[EulaService] Loaded: accepted=${_state.eulaAccepted} '
      'savedVersion=${_state.eulaVersion} currentVersion=$currentEulaVersion',
    );
  }

  // ── Checks ────────────────────────────────────────────────────────────────

  /// Returns [true] when the user must be shown the EULA before proceeding.
  ///
  /// This is the case when:
  /// * The user has never accepted the EULA, OR
  /// * A new EULA version has been published since the last acceptance.
  bool get eulaRequired {
    if (!_state.eulaAccepted) return true;
    return _state.eulaVersion < currentEulaVersion;
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  /// Records that the user has accepted the EULA at the current version.
  Future<void> acceptEula() async {
    _state = LegalState(
      eulaAccepted: true,
      eulaVersion: currentEulaVersion,
      acceptedAt: DateTime.now().toUtc(),
    );
    await _storage.saveState(_state);
    debugPrint('[EulaService] EULA accepted (v$currentEulaVersion)');
  }

  /// Clears any saved consent (intended for reset/testing flows only).
  Future<void> resetConsent() async {
    await _storage.clearState();
    _state = const LegalState.initial();
    debugPrint('[EulaService] Consent reset');
  }
}

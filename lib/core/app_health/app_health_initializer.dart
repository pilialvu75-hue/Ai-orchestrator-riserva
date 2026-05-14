import 'package:flutter/foundation.dart';

import 'package:ai_orchestrator/core/app_health/contracts/abstract_feature_flags_service.dart';
import 'package:ai_orchestrator/core/app_health/contracts/abstract_remote_config_service.dart';
import 'package:ai_orchestrator/core/app_health/contracts/abstract_telemetry_service.dart';
import 'package:ai_orchestrator/core/app_health/models/app_version_policy.dart';
import 'package:ai_orchestrator/core/app_health/models/safe_mode_state.dart';

/// Lightweight coordinator for the app-health subsystem.
///
/// [AppHealthInitializer] performs the safe-init sequence in the correct
/// order: remote config fetch first, then feature-flags warm-up, then
/// version-gate enforcement. Any failure is absorbed and degraded safely
/// — this class must never throw, and must never block the main startup
/// path by more than a few milliseconds when all backends are stubs.
///
/// Usage (called once from [RuntimeBootstrap.initialize] or similar):
/// ```dart
/// final health = AppHealthInitializer(
///   telemetry: sl<AbstractTelemetryService>(),
///   featureFlags: sl<AbstractFeatureFlagsService>(),
///   remoteConfig: sl<AbstractRemoteConfigService>(),
///   versionPolicy: AppVersionPolicy(minimumSupportedVersion: '1.0.0'),
///   currentAppVersion: appVersion,
/// );
/// final state = await health.initialize();
/// ```
class AppHealthInitializer {
  const AppHealthInitializer({
    required this.telemetry,
    required this.featureFlags,
    required this.remoteConfig,
    required this.versionPolicy,
    required this.currentAppVersion,
  });

  final AbstractTelemetryService telemetry;
  final AbstractFeatureFlagsService featureFlags;
  final AbstractRemoteConfigService remoteConfig;
  final AppVersionPolicy versionPolicy;
  final String currentAppVersion;

  /// Runs the health-init sequence and returns the resolved [SafeModeState].
  ///
  /// The returned state can be stored in the DI container or surfaced to a
  /// health-aware Bloc/cubit so that UI components can react without
  /// coupling directly to this initializer.
  Future<SafeModeState> initialize() async {
    SafeModeState state = SafeModeState.normal;

    // 1. Remote-config fetch (non-blocking; failures degrade gracefully).
    try {
      await remoteConfig.fetch();
    } catch (error, stackTrace) {
      telemetry.logError(
        error,
        stackTrace: stackTrace,
        reason: 'app_health_init/remote_config_fetch',
      );
      state = SafeModeState.degraded;
    }

    // 2. Feature-flags warm-up probe (sanity check only).
    try {
      featureFlags.getBool('_health_probe');
    } catch (error, stackTrace) {
      telemetry.logError(
        error,
        stackTrace: stackTrace,
        reason: 'app_health_init/feature_flags_probe',
      );
      state = SafeModeState.degraded;
    }

    // 3. Version gate.
    if (versionPolicy.isBlocked(currentAppVersion)) {
      telemetry.logEvent(
        'version_blocked',
        parameters: {
          'current': currentAppVersion,
          'minimum': versionPolicy.minimumSupportedVersion,
        },
      );
      state = SafeModeState.emergency;
    }

    debugPrint(
      '[AppHealth] init complete — version=$currentAppVersion state=$state',
    );
    return state;
  }
}

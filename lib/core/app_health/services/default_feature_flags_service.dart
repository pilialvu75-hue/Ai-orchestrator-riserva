import 'package:ai_orchestrator/core/app_health/contracts/abstract_feature_flags_service.dart';
import 'package:ai_orchestrator/core/config/runtime/feature_flags.dart';

/// Default feature-flags implementation backed by the existing [FeatureFlags]
/// value object.
///
/// Known flags (declared in [FeatureFlagKeys]) are resolved from the
/// [FeatureFlags] instance; any unknown flag falls back to its [defaultValue]
/// so that new flags can be introduced incrementally without breaking
/// existing flag consumers.
///
/// Future hook: replace the [FeatureFlags] source with a value fetched from
/// [AbstractRemoteConfigService] to enable runtime / A-B overrides without
/// a rebuild.
class DefaultFeatureFlagsService implements AbstractFeatureFlagsService {
  const DefaultFeatureFlagsService({
    FeatureFlags flags = const FeatureFlags(),
  }) : _flags = flags;

  final FeatureFlags _flags;

  @override
  bool getBool(String flag, {bool defaultValue = false}) {
    return switch (flag) {
      FeatureFlagKeys.enableMultiBrainRouting =>
        _flags.enableMultiBrainRouting,
      FeatureFlagKeys.enableRoleBasedModelSelection =>
        _flags.enableRoleBasedModelSelection,
      FeatureFlagKeys.enableAdvancedAgentTelemetry =>
        _flags.enableAdvancedAgentTelemetry,
      _ => defaultValue,
    };
  }

  @override
  String getString(String flag, {String defaultValue = ''}) {
    // No string flags defined in the initial hardcoded set.
    return defaultValue;
  }

  @override
  int getInt(String flag, {int defaultValue = 0}) {
    // No integer flags defined in the initial hardcoded set.
    return defaultValue;
  }
}

/// Abstract contract for feature-flag resolution.
///
/// Feature flags isolate experimental or rollout-gated behaviour from
/// stable code paths. Concrete implementations may source values from
/// hardcoded defaults, SharedPreferences, or a remote A/B framework —
/// the calling code never cares which.
abstract class AbstractFeatureFlagsService {
  /// Returns the boolean value of [flag], or [defaultValue] when the flag
  /// is unknown or unavailable.
  bool getBool(String flag, {bool defaultValue = false});

  /// Returns the string value of [flag], or [defaultValue] when the flag
  /// is unknown or unavailable.
  String getString(String flag, {String defaultValue = ''});

  /// Returns the integer value of [flag], or [defaultValue] when the flag
  /// is unknown or unavailable.
  int getInt(String flag, {int defaultValue = 0});
}

/// Well-known flag keys used throughout the application.
///
/// Centralising keys here prevents typo-driven divergence between writer
/// and reader sites.
abstract final class FeatureFlagKeys {
  FeatureFlagKeys._();

  static const String enableMultiBrainRouting = 'enable_multi_brain_routing';
  static const String enableRoleBasedModelSelection =
      'enable_role_based_model_selection';
  static const String enableAdvancedAgentTelemetry =
      'enable_advanced_agent_telemetry';
}

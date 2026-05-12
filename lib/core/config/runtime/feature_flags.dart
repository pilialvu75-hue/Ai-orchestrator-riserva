/// Experimental feature gates for staged rollout.
class FeatureFlags {
  const FeatureFlags({
    this.enableMultiBrainRouting = false,
    this.enableRoleBasedModelSelection = false,
    this.enableAdvancedAgentTelemetry = false,
  });

  final bool enableMultiBrainRouting;
  final bool enableRoleBasedModelSelection;
  final bool enableAdvancedAgentTelemetry;

  FeatureFlags copyWith({
    bool? enableMultiBrainRouting,
    bool? enableRoleBasedModelSelection,
    bool? enableAdvancedAgentTelemetry,
  }) {
    return FeatureFlags(
      enableMultiBrainRouting:
          enableMultiBrainRouting ?? this.enableMultiBrainRouting,
      enableRoleBasedModelSelection: enableRoleBasedModelSelection ??
          this.enableRoleBasedModelSelection,
      enableAdvancedAgentTelemetry:
          enableAdvancedAgentTelemetry ?? this.enableAdvancedAgentTelemetry,
    );
  }

  // TODO(future): source feature flags from remote config and A/B framework.
}

/// Runtime configuration toggles for orchestrator behavior.
class RuntimeConfig {
  const RuntimeConfig({
    this.offlineMode = false,
    this.allowCloudFallback = true,
    this.allowBackgroundAgents = true,
    this.debugMode = false,
  });

  final bool offlineMode;
  final bool allowCloudFallback;
  final bool allowBackgroundAgents;
  final bool debugMode;

  RuntimeConfig copyWith({
    bool? offlineMode,
    bool? allowCloudFallback,
    bool? allowBackgroundAgents,
    bool? debugMode,
  }) {
    return RuntimeConfig(
      offlineMode: offlineMode ?? this.offlineMode,
      allowCloudFallback: allowCloudFallback ?? this.allowCloudFallback,
      allowBackgroundAgents: allowBackgroundAgents ?? this.allowBackgroundAgents,
      debugMode: debugMode ?? this.debugMode,
    );
  }
}

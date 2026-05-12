class RuntimeFlags {
  const RuntimeFlags({
    this.offlineMode = false,
    this.allowCloudFallback = true,
    this.allowBackgroundAgents = true,
    this.debugMode = false,
  });

  final bool offlineMode;
  final bool allowCloudFallback;
  final bool allowBackgroundAgents;
  final bool debugMode;
}

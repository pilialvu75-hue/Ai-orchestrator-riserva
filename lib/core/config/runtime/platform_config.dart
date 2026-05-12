/// High-level platform metadata used by config decisions.
enum PlatformType {
  unknown,
  android,
  ios,
  windows,
  macos,
  linux,
  web,
}

/// Placeholder platform config contract for runtime policy selection.
class PlatformConfig {
  const PlatformConfig({
    this.platformType = PlatformType.unknown,
    this.supportsLocalModels = false,
    this.supportsBackgroundAgents = false,
  });

  final PlatformType platformType;
  final bool supportsLocalModels;
  final bool supportsBackgroundAgents;

  static PlatformConfig detect() {
    // TODO(future): implement platform detection via conditional imports.
    return const PlatformConfig();
  }
}

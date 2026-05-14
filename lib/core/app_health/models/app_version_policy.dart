import 'package:ai_orchestrator/core/system/update/version_comparator.dart';

/// Defines the minimum version policy for this application.
///
/// [AppVersionPolicy] is intentionally a pure value object — it holds no
/// mutable state and performs no I/O. Instances are typically constructed
/// from a remote manifest fetch or baked-in constants and then injected
/// wherever version-gating decisions are needed.
///
/// Future hook: replace [minimumSupportedVersion] with a value sourced
/// from [AbstractRemoteConfigService] to allow server-side blocking without
/// a new build.
class AppVersionPolicy {
  const AppVersionPolicy({
    required this.minimumSupportedVersion,
    this.comparator = const VersionComparator(),
  });

  /// Semantic-version string (e.g. `'1.2.0'`) below which the app must
  /// refuse to operate and direct the user to update.
  final String minimumSupportedVersion;

  /// Injected comparator — defaults to the existing [VersionComparator]
  /// so no additional dependency is introduced.
  final VersionComparator comparator;

  /// Returns `true` when [currentVersion] is strictly below
  /// [minimumSupportedVersion] and the app should be blocked from running.
  bool isBlocked(String currentVersion) {
    return !comparator.isCompatible(
      currentVersion: currentVersion,
      minSupported: minimumSupportedVersion,
    );
  }

  /// Convenience factory that creates a policy from a raw manifest map.
  ///
  /// Reads the `min_supported` key; falls back to `'0.0.0'` if absent so
  /// that a missing policy never accidentally blocks all users.
  factory AppVersionPolicy.fromJson(
    Map<String, dynamic> json, {
    VersionComparator comparator = const VersionComparator(),
  }) {
    final raw = json['min_supported'] as String?;
    return AppVersionPolicy(
      minimumSupportedVersion:
          (raw != null && raw.isNotEmpty) ? raw : '0.0.0',
      comparator: comparator,
    );
  }

  @override
  String toString() =>
      'AppVersionPolicy(minimumSupportedVersion: $minimumSupportedVersion)';
}

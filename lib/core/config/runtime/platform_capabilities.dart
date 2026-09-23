import 'package:flutter/foundation.dart';

/// Canonical host-platform identity used at feature/native capability boundaries.
///
/// Feature code should ask for a capability rather than treating every
/// non-Android platform as Windows. Specialized platform services remain free
/// to use their own adapters internally.
enum AppHostPlatform {
  android,
  ios,
  windows,
  macos,
  linux,
  web,
  other,
}

final class AppPlatformCapabilities {
  const AppPlatformCapabilities(this.host);

  final AppHostPlatform host;

  factory AppPlatformCapabilities.current() {
    if (kIsWeb) {
      return const AppPlatformCapabilities(AppHostPlatform.web);
    }

    return AppPlatformCapabilities(
      fromTargetPlatform(defaultTargetPlatform),
    );
  }

  static AppHostPlatform fromTargetPlatform(TargetPlatform platform) {
    return switch (platform) {
      TargetPlatform.android => AppHostPlatform.android,
      TargetPlatform.iOS => AppHostPlatform.ios,
      TargetPlatform.windows => AppHostPlatform.windows,
      TargetPlatform.macOS => AppHostPlatform.macos,
      TargetPlatform.linux => AppHostPlatform.linux,
      TargetPlatform.fuchsia => AppHostPlatform.other,
    };
  }

  bool get supportsAndroidIntents => host == AppHostPlatform.android;

  String get label => switch (host) {
        AppHostPlatform.android => 'Android',
        AppHostPlatform.ios => 'iOS',
        AppHostPlatform.windows => 'Windows',
        AppHostPlatform.macos => 'macOS',
        AppHostPlatform.linux => 'Linux',
        AppHostPlatform.web => 'Web',
        AppHostPlatform.other => 'questa piattaforma',
      };
}

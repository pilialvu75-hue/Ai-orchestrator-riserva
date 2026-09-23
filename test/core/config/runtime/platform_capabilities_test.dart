import 'package:ai_orchestrator/core/config/runtime/platform_capabilities.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maps every Flutter target to a distinct host identity', () {
    expect(
      AppPlatformCapabilities.fromTargetPlatform(TargetPlatform.android),
      AppHostPlatform.android,
    );
    expect(
      AppPlatformCapabilities.fromTargetPlatform(TargetPlatform.iOS),
      AppHostPlatform.ios,
    );
    expect(
      AppPlatformCapabilities.fromTargetPlatform(TargetPlatform.windows),
      AppHostPlatform.windows,
    );
    expect(
      AppPlatformCapabilities.fromTargetPlatform(TargetPlatform.macOS),
      AppHostPlatform.macos,
    );
    expect(
      AppPlatformCapabilities.fromTargetPlatform(TargetPlatform.linux),
      AppHostPlatform.linux,
    );
    expect(
      AppPlatformCapabilities.fromTargetPlatform(TargetPlatform.fuchsia),
      AppHostPlatform.other,
    );
  });

  test('Android intents are advertised only on Android', () {
    for (final host in AppHostPlatform.values) {
      final capabilities = AppPlatformCapabilities(host);
      expect(
        capabilities.supportsAndroidIntents,
        host == AppHostPlatform.android,
        reason: 'host=$host',
      );
    }
  });

  test('unsupported host labels are not collapsed to Windows', () {
    expect(
      const AppPlatformCapabilities(AppHostPlatform.linux).label,
      'Linux',
    );
    expect(
      const AppPlatformCapabilities(AppHostPlatform.macos).label,
      'macOS',
    );
    expect(
      const AppPlatformCapabilities(AppHostPlatform.ios).label,
      'iOS',
    );
    expect(
      const AppPlatformCapabilities(AppHostPlatform.web).label,
      'Web',
    );
  });
}

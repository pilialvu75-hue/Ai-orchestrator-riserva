import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app/app_shell_router.dart';

void main() {
  group('resolveAppShellTarget', () {
    test('routes native Windows to the desktop shell', () {
      expect(
        resolveAppShellTarget(TargetPlatform.windows, isWeb: false),
        AppShellTarget.windowsDesktop,
      );
    });

    test('keeps Android on the standard shell', () {
      expect(
        resolveAppShellTarget(TargetPlatform.android, isWeb: false),
        AppShellTarget.standard,
      );
    });

    test('does not treat Windows-hosted web as native desktop', () {
      expect(
        resolveAppShellTarget(TargetPlatform.windows, isWeb: true),
        AppShellTarget.standard,
      );
    });
  });
}

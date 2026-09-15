import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'package:ai_orchestrator/app/app_shell.dart';
import 'package:ai_orchestrator/app/desktop/desktop_app_shell.dart';

enum AppShellTarget {
  standard,
  windowsDesktop,
}

AppShellTarget resolveAppShellTarget(
  TargetPlatform platform, {
  required bool isWeb,
}) {
  if (!isWeb && platform == TargetPlatform.windows) {
    return AppShellTarget.windowsDesktop;
  }
  return AppShellTarget.standard;
}

class AppShellRouter extends StatelessWidget {
  const AppShellRouter({super.key});

  @override
  Widget build(BuildContext context) {
    final target = resolveAppShellTarget(
      defaultTargetPlatform,
      isWeb: kIsWeb,
    );

    return switch (target) {
      AppShellTarget.windowsDesktop => const DesktopAppShell(),
      AppShellTarget.standard => const AppShell(),
    };
  }
}

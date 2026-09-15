import 'package:flutter/widgets.dart';

import 'package:ai_orchestrator/app/app_shell.dart';

/// Windows desktop entry shell.
///
/// This first routing ring deliberately delegates to the existing application
/// shell so Android behavior and shared application services remain untouched.
/// The desktop-specific navigation/workspace chrome is added in the next rings
/// behind this stable platform boundary.
class DesktopAppShell extends StatelessWidget {
  const DesktopAppShell({super.key});

  @override
  Widget build(BuildContext context) => const AppShell();
}

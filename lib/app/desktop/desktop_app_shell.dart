import 'package:flutter/material.dart';

import 'package:ai_orchestrator/app/app_shell.dart';

/// Windows desktop shell.
///
/// Keeps one persistent browser-like chrome above a nested Navigator so pages
/// opened by the shared AppShell (Assistant, Cantiere, Settings, etc.) remain
/// inside the desktop workspace instead of replacing the whole desktop frame.
///
/// This is the second desktop shell ring: persistent navigation + home/back.
/// Project-per-tab/session ownership is intentionally added in the next ring so
/// it can be implemented without changing Android navigation semantics.
class DesktopAppShell extends StatefulWidget {
  const DesktopAppShell({super.key});

  @override
  State<DesktopAppShell> createState() => _DesktopAppShellState();
}

class _DesktopAppShellState extends State<DesktopAppShell> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final _DesktopNavigationObserver _observer = _DesktopNavigationObserver();

  bool get _canPop => _navigatorKey.currentState?.canPop() ?? false;

  void _goHome() {
    _navigatorKey.currentState?.popUntil((route) => route.isFirst);
  }

  Future<void> _goBack() async {
    await _navigatorKey.currentState?.maybePop();
  }

  @override
  void initState() {
    super.initState();
    _observer.onChanged = () {
      if (mounted) setState(() {});
    };
  }

  @override
  void dispose() {
    _observer.onChanged = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Material(
              elevation: 2,
              color: theme.colorScheme.surface,
              child: SizedBox(
                height: 48,
                child: Row(
                  children: [
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Indietro',
                      onPressed: _canPop ? _goBack : null,
                      icon: const Icon(Icons.arrow_back),
                    ),
                    IconButton(
                      tooltip: 'Menu principale',
                      onPressed: _goHome,
                      icon: const Icon(Icons.home_outlined),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          constraints: const BoxConstraints(maxWidth: 320),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(10),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.desktop_windows_outlined, size: 18),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  _canPop ? 'AI Orchestrator • workspace' : 'AI Orchestrator',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Navigator(
                key: _navigatorKey,
                observers: [_observer],
                onGenerateRoute: (_) => MaterialPageRoute<void>(
                  settings: const RouteSettings(name: 'home'),
                  builder: (_) => const AppShell(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DesktopNavigationObserver extends NavigatorObserver {
  VoidCallback? onChanged;

  void _notify() => onChanged?.call();

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _notify();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _notify();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _notify();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _notify();
  }
}

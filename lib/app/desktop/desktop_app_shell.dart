import 'package:flutter/material.dart';

import 'package:ai_orchestrator/app/app_shell.dart';
import 'package:ai_orchestrator/app/desktop/desktop_workspace_scope.dart';

/// Native Windows browser-like workspace shell.
///
/// Each tab owns an independent [AppShell] and nested [Navigator]. This keeps
/// Assistant/Cantiere state alive while the owner switches between projects.
/// New Cantiere conversations requested from a desktop workspace open in a new
/// tab instead of replacing the current project.
class DesktopAppShell extends StatefulWidget {
  const DesktopAppShell({super.key});

  @override
  State<DesktopAppShell> createState() => _DesktopAppShellState();
}

class _DesktopAppShellState extends State<DesktopAppShell> {
  final List<_DesktopWorkspaceEntry> _workspaces = <_DesktopWorkspaceEntry>[];
  int _activeIndex = 0;
  int _nextWorkspaceId = 1;

  _DesktopWorkspaceEntry get _activeWorkspace => _workspaces[_activeIndex];

  @override
  void initState() {
    super.initState();
    _workspaces.add(_createWorkspace(title: 'AI Orchestrator'));
  }

  _DesktopWorkspaceEntry _createWorkspace({
    required String title,
    bool startInWorkshop = false,
  }) {
    final id = _nextWorkspaceId++;
    final observer = _DesktopNavigationObserver();
    final entry = _DesktopWorkspaceEntry(
      id: id,
      title: title,
      startInWorkshop: startInWorkshop,
      navigatorKey: GlobalKey<NavigatorState>(),
      observer: observer,
    );
    observer.onChanged = () {
      if (mounted) setState(() {});
    };
    return entry;
  }

  void _addWorkspace({
    String title = 'AI Orchestrator',
    bool startInWorkshop = false,
  }) {
    setState(() {
      _workspaces.add(
        _createWorkspace(
          title: title,
          startInWorkshop: startInWorkshop,
        ),
      );
      _activeIndex = _workspaces.length - 1;
    });
  }

  void _openNewCantiereWorkspace() {
    _addWorkspace(
      title: 'Cantiere',
      startInWorkshop: true,
    );
  }

  void _renameWorkspace(int id, String rawTitle) {
    final title = rawTitle.trim();
    if (title.isEmpty) return;
    final index = _workspaces.indexWhere((entry) => entry.id == id);
    if (index < 0 || _workspaces[index].title == title) return;
    setState(() {
      _workspaces[index].title = title;
    });
  }

  void _registerBeforeClose(
    int id,
    Future<void> Function() callback,
  ) {
    final index = _workspaces.indexWhere((entry) => entry.id == id);
    if (index >= 0) {
      _workspaces[index].beforeClose = callback;
    }
  }

  bool get _canPop =>
      _activeWorkspace.navigatorKey.currentState?.canPop() ?? false;

  void _goHome() {
    _activeWorkspace.navigatorKey.currentState
        ?.popUntil((route) => route.isFirst);
  }

  Future<void> _goBack() async {
    await _activeWorkspace.navigatorKey.currentState?.maybePop();
  }

  Future<void> _closeWorkspace(int index) async {
    if (_workspaces.length == 1) {
      _goHome();
      return;
    }

    final workspace = _workspaces[index];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Chiudere la scheda?'),
        content: Text(
          'La scheda “${workspace.title}” verrà chiusa. '
          'Se contiene un progetto Cantiere, lo stato viene parcheggiato '
          'prima della chiusura e resta recuperabile da Progetti.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Chiudi scheda'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final beforeClose = workspace.beforeClose;
    if (beforeClose != null) {
      try {
        await beforeClose();
      } catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                'Impossibile parcheggiare la scheda “${workspace.title}”: '
                '$error',
              ),
            ),
          );
        return;
      }
    }
    if (!mounted) return;

    setState(() {
      workspace.observer.onChanged = null;
      _workspaces.removeAt(index);
      if (_activeIndex > index) {
        _activeIndex -= 1;
      } else if (_activeIndex >= _workspaces.length) {
        _activeIndex = _workspaces.length - 1;
      }
    });
  }

  @override
  void dispose() {
    for (final workspace in _workspaces) {
      workspace.observer.onChanged = null;
    }
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
                height: 50,
                child: Row(
                  children: [
                    const SizedBox(width: 6),
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
                    const VerticalDivider(width: 16, indent: 10, endIndent: 10),
                    Expanded(
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        itemCount: _workspaces.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 4),
                        itemBuilder: (context, index) {
                          final workspace = _workspaces[index];
                          final selected = index == _activeIndex;
                          return _DesktopWorkspaceTab(
                            title: workspace.title,
                            selected: selected,
                            onSelect: () {
                              if (!selected) {
                                setState(() => _activeIndex = index);
                              }
                            },
                            onClose: () => _closeWorkspace(index),
                          );
                        },
                      ),
                    ),
                    IconButton(
                      tooltip: 'Nuova scheda',
                      onPressed: _addWorkspace,
                      icon: const Icon(Icons.add),
                    ),
                    const SizedBox(width: 6),
                  ],
                ),
              ),
            ),
            Expanded(
              child: IndexedStack(
                index: _activeIndex,
                children: _workspaces
                    .map(
                      (workspace) => DesktopWorkspaceScope(
                        workspaceId: workspace.id,
                        openNewCantiereTab: _openNewCantiereWorkspace,
                        renameWorkspace: (title) =>
                            _renameWorkspace(workspace.id, title),
                        registerBeforeClose: (callback) =>
                            _registerBeforeClose(workspace.id, callback),
                        child: Navigator(
                          key: workspace.navigatorKey,
                          observers: [workspace.observer],
                          onGenerateRoute: (_) => MaterialPageRoute<void>(
                            settings: const RouteSettings(name: 'home'),
                            builder: (_) => AppShell(
                              openWorkshopOnStart: workspace.startInWorkshop,
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(growable: false),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DesktopWorkspaceEntry {
  _DesktopWorkspaceEntry({
    required this.id,
    required this.title,
    required this.startInWorkshop,
    required this.navigatorKey,
    required this.observer,
  });

  final int id;
  String title;
  final bool startInWorkshop;
  final GlobalKey<NavigatorState> navigatorKey;
  final _DesktopNavigationObserver observer;
  Future<void> Function()? beforeClose;
}

class _DesktopWorkspaceTab extends StatelessWidget {
  const _DesktopWorkspaceTab({
    required this.title,
    required this.selected,
    required this.onSelect,
    required this.onClose,
  });

  final String title;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = selected
        ? theme.colorScheme.surfaceContainerHighest
        : theme.colorScheme.surface;

    return Material(
      color: background,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(9)),
      child: InkWell(
        onTap: onSelect,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(9)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: 140,
            maxWidth: 260,
          ),
          child: Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  selected
                      ? Icons.tab
                      : Icons.tab_outlined,
                  size: 17,
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Chiudi scheda',
                  visualDensity: VisualDensity.compact,
                  onPressed: onClose,
                  icon: const Icon(Icons.close, size: 16),
                ),
              ],
            ),
          ),
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

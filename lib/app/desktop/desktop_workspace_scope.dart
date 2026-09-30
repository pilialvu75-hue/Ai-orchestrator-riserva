import 'package:flutter/widgets.dart';

/// Optional bridge exposed only by the native Windows desktop shell.
///
/// Shared pages can use it without changing Android/web behavior. When absent,
/// the caller simply falls back to the existing in-page navigation.
class DesktopWorkspaceScope extends InheritedWidget {
  const DesktopWorkspaceScope({
    required this.workspaceId,
    required this.openNewCantiereTab,
    required this.renameWorkspace,
    required this.registerBeforeClose,
    required super.child,
    super.key,
  });

  final int workspaceId;
  final VoidCallback openNewCantiereTab;
  final ValueChanged<String> renameWorkspace;
  final ValueChanged<Future<void> Function()> registerBeforeClose;

  static DesktopWorkspaceScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<DesktopWorkspaceScope>();
  }

  @override
  bool updateShouldNotify(DesktopWorkspaceScope oldWidget) {
    return workspaceId != oldWidget.workspaceId ||
        openNewCantiereTab != oldWidget.openNewCantiereTab ||
        renameWorkspace != oldWidget.renameWorkspace ||
        registerBeforeClose != oldWidget.registerBeforeClose;
  }
}

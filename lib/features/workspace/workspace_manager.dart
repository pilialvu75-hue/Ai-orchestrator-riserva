import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';

class WorkspaceManager {
  WorkspaceManager({
    required PreferencesService preferencesService,
  }) : _preferencesService = preferencesService;

  static const String _activeWorkspacePrefKey = 'active_workspace_root';
  final PreferencesService _preferencesService;

  Future<void> setActiveWorkspaceRoot(String rootPath) {
    return _preferencesService.setString(_activeWorkspacePrefKey, rootPath);
  }

  String? getActiveWorkspaceRoot() {
    return _preferencesService.getString(_activeWorkspacePrefKey);
  }
}

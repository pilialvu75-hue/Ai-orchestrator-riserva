import 'package:ai_orchestrator/core/config/storage/config_storage.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';

/// Backward-compatible facade over [PreferencesService].
class PreferencesManager implements ConfigStorage {
  const PreferencesManager(this._service);

  final PreferencesService _service;

  static const String runtimeOfflineModeKey = 'runtime.offline_mode';
  static const String runtimeAllowCloudFallbackKey =
      'runtime.allow_cloud_fallback';
  static const String runtimeAllowBackgroundAgentsKey =
      'runtime.allow_background_agents';
  static const String runtimeDebugModeKey = 'runtime.debug_mode';
  static const String selectedOrchestratorModelKey =
      'models.selected.orchestrator';
  static const String selectedGeniusModelKey = 'models.selected.genius';
  static const String selectedSageModelKey = 'models.selected.sage';

  @override
  Future<String?> readString(String key) async => _service.getString(key);

  @override
  Future<bool?> readBool(String key) async => _service.getBool(key);

  @override
  Future<void> writeString(String key, String value) async {
    await _service.setString(key, value);
  }

  @override
  Future<void> writeBool(String key, bool value) async {
    await _service.setBool(key, value);
  }

  @override
  Future<void> remove(String key) async {
    await _service.remove(key);
  }
}

import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:ai_orchestrator/core/config/storage/config_storage.dart';

class ConfigRepository implements ConfigStorage {
  const ConfigRepository(this._preferencesService);

  final PreferencesService _preferencesService;

  String? getString(String key) => _preferencesService.getString(key);
  bool? getBool(String key) => _preferencesService.getBool(key);

  Future<void> setString(String key, String value) async {
    await _preferencesService.setString(key, value);
  }

  Future<void> setBool(String key, bool value) async {
    await _preferencesService.setBool(key, value);
  }

  @override
  Future<void> remove(String key) async {
    await _preferencesService.remove(key);
  }

  @override
  Future<String?> readString(String key) async => getString(key);

  @override
  Future<bool?> readBool(String key) async => getBool(key);

  @override
  Future<void> writeString(String key, String value) async {
    await setString(key, value);
  }

  @override
  Future<void> writeBool(String key, bool value) async {
    await setBool(key, value);
  }
}

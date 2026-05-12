import 'package:shared_preferences/shared_preferences.dart';

class PreferencesService {
  const PreferencesService(this._preferences);

  final SharedPreferences _preferences;

  String? getString(String key) => _preferences.getString(key);
  bool? getBool(String key) => _preferences.getBool(key);

  Future<void> setString(String key, String value) async {
    await _preferences.setString(key, value);
  }

  Future<void> setBool(String key, bool value) async {
    await _preferences.setBool(key, value);
  }

  Future<void> remove(String key) async {
    await _preferences.remove(key);
  }
}

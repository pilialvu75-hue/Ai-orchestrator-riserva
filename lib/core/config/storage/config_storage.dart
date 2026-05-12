/// Persistence abstraction for modular configuration state.
abstract class ConfigStorage {
  Future<void> writeString(String key, String value);
  Future<String?> readString(String key);
  Future<void> writeBool(String key, bool value);
  Future<bool?> readBool(String key);
  Future<void> remove(String key);
}

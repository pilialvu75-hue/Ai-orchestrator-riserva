import 'package:flutter_secure_storage/flutter_secure_storage.dart';

final class ModuleLibraryGitHubConfigStore {
  ModuleLibraryGitHubConfigStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const String _clientIdKey =
      'ai_orchestrator.module_library.github.client_id.v1';

  final FlutterSecureStorage _storage;

  Future<String?> loadClientId() async {
    final value = (await _storage.read(key: _clientIdKey))?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  Future<void> saveClientId(String clientId) async {
    final normalized = clientId.trim();
    if (normalized.isEmpty) {
      throw const FormatException('GitHub App client id is required.');
    }
    await _storage.write(key: _clientIdKey, value: normalized);
  }

  Future<void> clearClientId() => _storage.delete(key: _clientIdKey);
}

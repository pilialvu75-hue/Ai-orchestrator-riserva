import 'package:ai_orchestrator/app_factory/workshop/workshop_factory.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_github_auth.dart';
import 'package:flutter_test/flutter_test.dart';

final class _MemorySecretStorage implements WorkshopLibrarySecretStorage {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

void main() {
  test('production factory wires Researcher Library handoff without auth side effects', () {
    final credentialStore = WorkshopLibraryGitHubCredentialStore(
      storage: _MemorySecretStorage(),
    );

    final handoff = WorkshopFactory.createResearchLibraryHandoff(
      credentialStore: credentialStore,
    );

    expect(handoff, isNotNull);
  });
}

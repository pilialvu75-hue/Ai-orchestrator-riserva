import 'dart:convert';

import 'package:ai_orchestrator/core/runtime/inference/cloud_credential_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CloudCredentialStore', () {
    test('environment fallback remains memory-only', () async {
      final storage = _MemorySecretStorage();
      final store = CloudCredentialStore(storage: storage);

      await store.initialize(
        environmentFallbacks: const <String, String>{
          'openAi': 'env-key',
        },
      );

      expect(store.secretFor('openAi'), 'env-key');
      expect(store.snapshotFor('openAi').fromEnvironmentFallback, isTrue);
      expect(storage.values, isEmpty);
    });

    test('secure API key overrides environment fallback and can rotate', () async {
      final storage = _MemorySecretStorage();
      final store = CloudCredentialStore(storage: storage);

      await store.initialize(
        environmentFallbacks: const <String, String>{
          'openAi': 'env-key',
        },
      );

      await store.setApiKey('openAi', 'first-key');
      expect(store.secretFor('openAi'), 'first-key');
      expect(store.snapshotFor('openAi').kind, CloudCredentialKind.apiKey);
      expect(store.snapshotFor('openAi').fromEnvironmentFallback, isFalse);

      await store.setApiKey('openAi', 'second-key');
      expect(store.secretFor('openAi'), 'second-key');
      expect(storage.values.length, 1);
    });

    test('persisted credentials are recovered after reinitialization', () async {
      final storage = _MemorySecretStorage();
      final first = CloudCredentialStore(storage: storage);
      await first.initialize();
      await first.setApiKey('claude', 'persisted-key');

      final second = CloudCredentialStore(storage: storage);
      await second.initialize();

      expect(second.secretFor('claude'), 'persisted-key');
      expect(second.snapshotFor('claude').configured, isTrue);
    });

    test('OAuth writes fail closed when the active adapter has no OAuth flow',
        () async {
      final storage = _MemorySecretStorage();
      final store = CloudCredentialStore(storage: storage);
      await store.initialize();

      for (final provider in <String>['gemini', 'copilot']) {
        await expectLater(
          store.setOAuthAccessToken(provider, 'oauth-token'),
          throwsUnsupportedError,
        );
        expect(store.secretFor(provider), isNull);
      }
    });

    test('legacy OAuth record is never exposed as an API key', () async {
      final storage = _MemorySecretStorage();
      storage.values['ai_orchestrator.cloud.credential.v1.gemini'] = jsonEncode(
        <String, Object?>{
          'version': 1,
          'providerId': 'gemini',
          'kind': 'oauthAccessToken',
          'secret': 'legacy-oauth-token',
          'accountId': null,
          'expiresAt': null,
        },
      );

      final store = CloudCredentialStore(storage: storage);
      await store.initialize();

      expect(store.secretFor('gemini'), isNull);
      expect(store.snapshotFor('gemini').configured, isFalse);
      expect(
        store.snapshotFor('gemini').kind,
        CloudCredentialKind.oauthAccessToken,
      );
    });

    test('unreadable provider is isolated without deleting any credentials',
        () async {
      final storage = _FailureInjectingSecretStorage();
      final initial = CloudCredentialStore(storage: storage);
      await initial.initialize();
      await initial.setApiKey('openAi', 'fake-key-a');
      await initial.setApiKey('claude', 'fake-key-b');

      storage.unreadableKey = 'ai_orchestrator.cloud.credential.v1.openAi';
      final recovered = CloudCredentialStore(storage: storage);
      await recovered.initialize();
      expect(recovered.isInitialized, isTrue);
      expect(recovered.isCredentialUnreadable('openAi'), isTrue);
      expect(recovered.snapshotFor('openAi').configured, isFalse);
      expect(recovered.secretFor('claude'), 'fake-key-b');
      expect(storage.values.length, 2);
      expect(storage.deletions, 0);

      storage.unreadableKey = null;
      await recovered.initialize();
      expect(recovered.isCredentialUnreadable('openAi'), isFalse);
      expect(recovered.secretFor('openAi'), 'fake-key-a');
    });

    test('failed removal preserves in-memory and persisted credentials',
        () async {
      final storage = _FailureInjectingSecretStorage();
      final store = CloudCredentialStore(storage: storage);
      await store.initialize();
      await store.setApiKey('openAi', 'fake-key');

      storage.failDeletes = true;
      await expectLater(store.remove('openAi'), throwsStateError);
      expect(store.secretFor('openAi'), 'fake-key');
      expect(storage.values.length, 1);
      expect(storage.deletions, 0);
    });

    test('explicit credential replacement resets unreadable marker', () async {
      final storage = _FailureInjectingSecretStorage();
      storage.unreadableKey = 'ai_orchestrator.cloud.credential.v1.openAi';
      final store = CloudCredentialStore(storage: storage);
      await store.initialize();
      expect(store.isCredentialUnreadable('openAi'), isTrue);
      expect(storage.deletions, 0);

      await store.setApiKey('openAi', 'fake-replacement');
      expect(store.isCredentialUnreadable('openAi'), isFalse);
      expect(store.secretFor('openAi'), 'fake-replacement');
      expect(storage.deletions, 0);
    });

    test('remove deletes the persisted secret and in-memory credential', () async {
      final storage = _MemorySecretStorage();
      final store = CloudCredentialStore(storage: storage);
      await store.initialize();
      await store.setApiKey('grok', 'secret');

      await store.remove('grok');

      expect(store.secretFor('grok'), isNull);
      expect(store.snapshotFor('grok').configured, isFalse);
      expect(storage.values, isEmpty);
    });
  });
}

final class _MemorySecretStorage implements CloudSecretStorage {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

final class _FailureInjectingSecretStorage implements CloudSecretStorage {
  final Map<String, String> values = <String, String>{};
  String? unreadableKey;
  bool failDeletes = false;
  int deletions = 0;

  @override
  Future<String?> read(String key) async {
    if (key == unreadableKey) throw StateError('synthetic decrypt failure');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failDeletes) throw StateError('synthetic delete failure');
    deletions++;
    values.remove(key);
  }
}

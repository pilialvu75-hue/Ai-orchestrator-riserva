import 'dart:convert';

import 'package:ai_orchestrator/core/runtime/inference/cloud_credential_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_disclosure_consent.dart';
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

    test('consent identity is stable after restart but rotates on every key edit',
        () async {
      final storage = _MemorySecretStorage();
      final original = CloudCredentialStore(storage: storage);
      await original.initialize();
      expect(original.consentBindingFor('openAi'), isNull);
      await original.setApiKey(
        'openAi', 'key', accountId: 'same-visible-account',
      );
      final first = original.consentBindingFor('openAi');
      expect(first, matches(RegExp(r'^[a-zA-Z0-9_-]{32}$')));
      expect(first, isNot(contains('same-visible-account')));
      expect(first, isNot('key'));


      final reopened = CloudCredentialStore(storage: storage);
      await reopened.initialize();
      expect(reopened.consentBindingFor('openAi'), first);
      await reopened.setApiKey(
        'openAi', 'key', accountId: 'same-visible-account',
      );
      final second = reopened.consentBindingFor('openAi');
      expect(second, isNot(first));
      final reopenedAgain = CloudCredentialStore(storage: storage);
      await reopenedAgain.initialize();
      expect(reopenedAgain.consentBindingFor('openAi'), second);
      await reopenedAgain.remove('openAi');
      expect(reopenedAgain.consentBindingFor('openAi'), isNull);
      await reopenedAgain.setApiKey(
        'openAi', 'key', accountId: 'same-visible-account',
      );
      expect(reopenedAgain.consentBindingFor('openAi'), isNot(second));
    });

    test('persistent Cloud grant is never inherited after same-account rekey',
        () async {
      final credentialStorage = _MemorySecretStorage();
      final credentials = CloudCredentialStore(storage: credentialStorage);
      await credentials.initialize();
      await credentials.setApiKey(
        'openAi', 'secret-one', accountId: 'display-account',
      );
      const scope = HybridDisclosureScope(
        HybridDisclosureOrigin.systemInstructions,
        HybridDisclosureSensitivity.publicOrNonPersonal,
      );
      final backend = _MemoryConsentStorage();
      final consent = HybridCloudDisclosureConsent(
        backend: backend,
        authorizeOwnerSession: (owner, session) async =>
            owner == 'local-owner' && session == 'local-session',
      );
      HybridCloudDisclosure disclosure(String binding) =>
          HybridCloudDisclosure(
            ownerId: 'local-owner',
            sessionId: 'local-session',
            providerId: 'openAi',
            accountId: 'display-account',
            credentialBindingId: binding,
            purpose: 'Answer the user',
            outboundText: 'Checked text',
            segments: const <HybridDisclosureSegment>[
              HybridDisclosureSegment(text: 'Checked text', scope: scope),
            ],
          );
      final old = disclosure(credentials.consentBindingFor('openAi')!);
      await consent.setStoredPreference(
        ownerId: old.ownerId,
        sessionId: old.sessionId,
        providerId: old.providerId,
        accountId: old.registryAccountId,
        scope: scope,
        preference: HybridCloudStoredConsent.allowAlways,
      );
      expect(await consent.authorize(disclosure: old), isTrue);
      final oldRules = backend.values.values.join();
      expect(oldRules, isNot(contains('secret-one')));
      expect(oldRules, isNot(contains('display-account')));

      await credentials.setApiKey(
        'openAi', 'secret-two', accountId: 'display-account',
      );
      final afterChange = disclosure(credentials.consentBindingFor('openAi')!);
      expect(afterChange.contentFingerprint, isNot(old.contentFingerprint));
      expect(afterChange.accountId, old.accountId);
      expect(afterChange.registryAccountId, isNot(old.registryAccountId));
      expect(await consent.storedPreference(
        ownerId: afterChange.ownerId,
        sessionId: afterChange.sessionId,
        providerId: afterChange.providerId,
        accountId: afterChange.registryAccountId,
        scope: scope,
      ), isNull);
      // Without an explicit new review, deny sending the same plaintext.
      expect(await consent.authorize(disclosure: afterChange), isFalse);
      // Legacy name-only approvals cannot be inherited either.
      await consent.setStoredPreference(
        ownerId: old.ownerId,
        sessionId: old.sessionId,
        providerId: old.providerId,
        accountId: old.accountId,
        scope: scope,
        preference: HybridCloudStoredConsent.allowAlways,
      );
      expect(await consent.authorize(disclosure: afterChange), isFalse);
    });

    test('legacy secret record gets a fresh permission epoch on secure restart',
        () async {
      final storage = _MemorySecretStorage();
      storage.values['ai_orchestrator.cloud.credential.v1.openAi'] =
          jsonEncode(<String, Object?>{
            'version': 1,
            'providerId': 'openAi',
            'kind': 'apiKey',
            'secret': 'legacy',
            'accountId': 'my-account',
            'expiresAt': null,
          });
      final credentials = CloudCredentialStore(storage: storage);
      await credentials.initialize();
      expect(credentials.secretFor('openAi'), 'legacy');
      final generation = credentials.consentBindingFor('openAi');
      expect(generation, matches(RegExp(r'^[a-zA-Z0-9_-]{32}$')));
      expect(storage.values.values.single, contains('consentEpoch'));
      final restarted = CloudCredentialStore(storage: storage);
      await restarted.initialize();
      expect(restarted.consentBindingFor('openAi'), generation);
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

final class _MemoryConsentStorage implements HybridCloudConsentStorage {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String key) async { values.remove(key); }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async { values[key] = value; }
}

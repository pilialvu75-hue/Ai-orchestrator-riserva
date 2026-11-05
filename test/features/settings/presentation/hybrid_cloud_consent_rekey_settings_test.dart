import 'package:ai_orchestrator/core/runtime/app_localizations.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_credential_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_disclosure_consent.dart';
import 'package:ai_orchestrator/features/settings/presentation/pages/modules/hybrid_cloud_consent_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

final class _ConsentStore implements HybridCloudConsentStorage {
  final data = <String, String>{};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async { data[key] = value; }
  @override
  Future<void> delete(String key) async { data.remove(key); }
}

final class _SecretStore implements CloudSecretStorage {
  final data = <String, String>{};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async { data[key] = value; }
  @override
  Future<void> delete(String key) async { data.remove(key); }
}

void main() {
  testWidgets('rekey during an open Cloud consent dialog cannot save grants',
      (tester) async {
    final backend = _ConsentStore();
    final credentials = CloudCredentialStore(storage: _SecretStore());
    await credentials.initialize();
    await credentials.setApiKey(
      'gemini', 'first-key', accountId: 'visible-account',
    );
    final previousGeneration = credentials.consentBindingFor('gemini');
    final manager = HybridCloudDisclosureConsent(
      backend: backend,
      authorizeOwnerSession: (owner, session) async =>
          owner == 'owner-a' && session == 'session-a',
    );
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('it'),
      supportedLocales: const <Locale>[
        Locale('it'), Locale('fr'), Locale('en'), Locale('es'),
      ],
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      home: HybridCloudConsentSettingsPage(
        manager: manager,
        ownerId: 'owner-a',
        sessionId: 'session-a',
        credentials: credentials,
      ),
    ));
    // Protected storage may complete after the first frame. Wait for the
    // actual enabled button rather than an indeterminate progress animation.
    final add = find.byKey(const Key('consent-add'));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pump(const Duration(milliseconds: 50));
      if (add.evaluate().length == 1 &&
          tester.widget<FilledButton>(add).onPressed != null) break;
    }
    expect(tester.widget<FilledButton>(add).onPressed, isNotNull);
    await tester.ensureVisible(add);
    await tester.pump();
    await tester.tap(add);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.byKey(const Key('consent-apply')), findsOneWidget);

    // Even if the account label is identical, this is a different
    // credential generation. An old settings dialog must not write to it.
    await credentials.setApiKey(
      'gemini', 'second-key', accountId: 'visible-account',
    );
    expect(credentials.consentBindingFor('gemini'), isNot(previousGeneration));
    await tester.tap(find.byKey(const Key('consent-apply')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(backend.data, isEmpty);
    final registryAccount = HybridCloudDisclosure.registryAccountFor(
      accountId: 'visible-account',
      credentialBindingId: credentials.consentBindingFor('gemini')!,
    );
    expect(await manager.listStoredPreferences(
      ownerId: 'owner-a',
      sessionId: 'session-a',
      providerId: 'gemini',
      accountId: registryAccount,
    ), isEmpty);
  });
}

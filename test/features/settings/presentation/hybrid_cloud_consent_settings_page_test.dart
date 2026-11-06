import 'package:ai_orchestrator/core/runtime/app_localizations.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_credential_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_disclosure_consent.dart';
import 'package:ai_orchestrator/features/settings/presentation/pages/modules/hybrid_cloud_consent_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

final class _PermissionMemory implements HybridCloudConsentStorage {
  final data = <String, String>{};

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async {
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    data.remove(key);
  }
}

final class _CredentialMemory implements CloudSecretStorage {
  final data = <String, String>{};

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async {
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    data.remove(key);
  }
}

void main() {
  Widget app(Widget page) => MaterialApp(
    locale: const Locale('it'),
    supportedLocales: const <Locale>[
      Locale('it'), Locale('en'), Locale('fr'),
      Locale('es'), Locale('de'),
    ],
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    home: page,
  );

  testWidgets('normal Settings entry cannot grant Cloud consent without auth',
      (tester) async {
    await tester.pumpWidget(
      app(const HybridCloudConsentSettingsPage()),
    );
    await tester.pumpAndSettle();
    expect(find.text('Consensi Cloud'), findsOneWidget);
    expect(find.byKey(const Key('consent-inactive')), findsOneWidget);
    expect(find.byKey(const Key('consent-add')), findsNothing);
    expect(find.byKey(const Key('consent-apply')), findsNothing);
  });

  testWidgets('authorized test profile lists and changes protected decisions',
      (tester) async {
    final backend = _PermissionMemory();
    final credentials = CloudCredentialStore(storage: _CredentialMemory());
    await credentials.initialize();
    await credentials.setApiKey('gemini', 'dummy-key',
        accountId: 'verified-test-account');
    final registryAccount = HybridCloudDisclosure.registryAccountFor(
      accountId: 'verified-test-account',
      credentialBindingId: credentials.consentBindingFor('gemini')!,
    );
    final manager = HybridCloudDisclosureConsent(
      backend: backend,
      authorizeOwnerSession: (ownerId, sessionId) async =>
          ownerId == 'verified-test-owner' &&
          sessionId == 'verified-test-chat',
    );

    await tester.pumpWidget(app(HybridCloudConsentSettingsPage(
      manager: manager,
      ownerId: 'verified-test-owner',
      sessionId: 'verified-test-chat',
      credentials: credentials,
    )));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('consent-inactive')), findsNothing);
    expect(find.byKey(const Key('consent-empty')), findsOneWidget);
    await tester.tap(find.byKey(const Key('consent-add')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('consent-origin')), findsOneWidget);
    expect(find.byKey(const Key('consent-level')), findsOneWidget);

    // Defaults to confirmed memories, preference-level, ask each time.
    await tester.tap(find.byKey(const Key('consent-apply')));
    await tester.pumpAndSettle();
    const scope = HybridDisclosureScope(
      HybridDisclosureOrigin.durableMemory,
      HybridDisclosureSensitivity.preference,
    );
    var rules = await manager.listStoredPreferences(
      ownerId: 'verified-test-owner',
      sessionId: 'verified-test-chat',
      providerId: 'gemini',
      accountId: registryAccount,
    );
    expect(rules[scope], HybridCloudStoredConsent.askEveryTime);
    expect(find.text('Ricordi confermati · Preferenze'), findsOneWidget);
    expect(find.text('Chiedi ogni volta'), findsOneWidget);

    // Changing existing rules never depends on reading actual memory text.
    await tester.tap(
      find.byKey(const Key('consent-edit-durableMemory-preference')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('consent-choice')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Non condividere mai').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('consent-apply')));
    await tester.pumpAndSettle();
    rules = await manager.listStoredPreferences(
      ownerId: 'verified-test-owner',
      sessionId: 'verified-test-chat',
      providerId: 'gemini',
      accountId: registryAccount,
    );
    expect(rules[scope], HybridCloudStoredConsent.neverShare);
    expect(find.text('Non condividere mai'), findsOneWidget);
    expect(backend.data.values.join(), isNot(contains('dummy-key')));
  });
}

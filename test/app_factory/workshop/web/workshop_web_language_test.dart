import 'package:ai_orchestrator/app_factory/workshop/workshop_checkpoint_store.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_cloud_broker.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_language.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Web language setting is independent and persists across reopening',
      () async {
    SharedPreferences.setMockInitialValues(
      <String, Object>{WorkshopWebLanguage.storageKey: 'fr'},
    );
    final original = await WorkshopWebLanguage.open();
    expect(original.code, 'fr');
    expect(original.text('Nuovo progetto'), 'Nouveau projet');
    expect(original.replyLanguageName, 'français');
    await original.select('es');
    final reopened = await WorkshopWebLanguage.open();
    expect(reopened.code, 'es');
    expect(reopened.text('Nuovo progetto'), 'Nuevo proyecto');
    expect(reopened.replyLanguageName, 'español');
  });

  test('Web language rejects unsupported settings safely', () {
    final selected = WorkshopWebLanguage(initialCode: 'xx');
    expect(selected.code, 'it');
    expect(WorkshopWebLanguage.normalize('FR'), 'fr');
    expect(selected.text('Nuovo progetto'), 'Nuovo progetto');
  });

  testWidgets('Web Status instantly follows selected locale without a network call',
      (tester) async {
    final language = WorkshopWebLanguage(initialCode: 'it');
    await tester.pumpWidget(
      MaterialApp(
        home: WorkshopWebLanguageScope(
          language: language,
          child: WorkshopWebShell(
            checkpointStore: Future<WorkshopCheckpointStore>.value(
              InMemoryWorkshopCheckpointStore(),
            ),
            cloudHealth: Future<WorkshopWebCloudBrokerHealth>.value(
              const WorkshopWebCloudBrokerHealth(
                capabilities:
                    WorkshopWebCloudBrokerHealth.requiredWorkshopCapabilities,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Cantiere Web'), findsOneWidget);
    expect(find.text('Cloud / AUTO execution'), findsOneWidget);

    await language.select('fr');
    await tester.pumpAndSettle();
    expect(find.text('Atelier Web'), findsOneWidget);
    expect(find.text('Exécution Cloud / AUTO'), findsOneWidget);

    await language.select('es');
    await tester.pumpAndSettle();
    expect(find.text('Taller Web'), findsOneWidget);
    expect(find.text('Inferencia Cloud / AUTO'), findsOneWidget);
  });
}

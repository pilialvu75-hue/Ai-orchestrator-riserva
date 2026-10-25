import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_app_emission_package.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_app_emissions_page.dart';

void main() {
  testWidgets(
      'catalogue opens the selected Windows result and exposes other targets',
      (tester) async {
    final windows = _package('windows', 'Stella ASUS');
    final android = _package('android', 'App Android');
    WorkshopAppEmissionPackage? opened;
    await tester.pumpWidget(MaterialApp(
        home: WorkshopAppEmissionsPage(
      packages: [windows, android],
      openApp: (package) async {
        opened = package;
      },
    )));
    expect(find.text('Stella ASUS'), findsOneWidget);
    expect(find.text('App Android'), findsOneWidget);
    expect(find.text('Avvia app'), findsOneWidget);
    await tester.tap(find.text('Avvia app'));
    await tester.pump();
    expect(opened, same(windows));
  });

  testWidgets('missing result reports a readable error and permits retry',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
        home: WorkshopAppEmissionsPage(
      packages: [_package('windows', 'Stella ASUS')],
      openApp: (_) async {
        calls++;
        throw StateError('private file diagnostic');
      },
    )));
    await tester.tap(find.text('Avvia app'));
    await tester.pump();
    expect(find.textContaining('Controlla che i file'), findsOneWidget);
    expect(find.textContaining('private file diagnostic'), findsNothing);
    await tester.tap(find.text('Avvia app'));
    await tester.pump();
    expect(calls, 2);
  });
}

WorkshopAppEmissionPackage _package(String target, String name) =>
    WorkshopAppEmissionPackage(
      id: 'fixture-$target',
      requestId: 'fixture-$target',
      target: target,
      artifactPath: 'fixture-output-$target',
      createdAt: DateTime(2026),
      appName: name,
    );

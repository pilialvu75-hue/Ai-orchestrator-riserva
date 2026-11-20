import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_generator_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('wide workspace keeps request and preview visible', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 850);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: WorkshopWebGeneratorWorkspace(
          composer: Center(child: Text('Editor della richiesta')),
        ),
      ),
    ));

    expect(find.text('Editor della richiesta'), findsOneWidget);
    expect(find.text('Nessuna app da visualizzare'), findsOneWidget);
    expect(find.text('Telefono'), findsOneWidget);
    expect(find.text('Desktop'), findsOneWidget);
  });

  testWidgets('compact workspace switches between request and preview', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: WorkshopWebGeneratorWorkspace(
          composer: Center(child: Text('Editor della richiesta')),
        ),
      ),
    ));

    expect(find.text('Editor della richiesta'), findsOneWidget);
    expect(find.text('Nessuna app da visualizzare'), findsNothing);

    await tester.tap(find.text('Anteprima interattiva'));
    await tester.pumpAndSettle();
    expect(find.text('Nessuna app da visualizzare'), findsOneWidget);

    await tester.tap(find.text('Richiesta'));
    await tester.pumpAndSettle();
    expect(find.text('Editor della richiesta'), findsOneWidget);
  });
}

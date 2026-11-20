import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_generator_workspace.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_platform_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('initial editor occupies the screen without preview', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 850);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: WorkshopWebGeneratorWorkspace(
          showIntro: true,
          intro: Center(child: Text('Editor grande del primo prompt')),
          composer: Center(child: Text('Chat successiva')),
        ),
      ),
    ));
    expect(find.text('Editor grande del primo prompt'), findsOneWidget);
    expect(find.text('Chat successiva'), findsNothing);
    expect(find.text('Anteprima interattiva'), findsNothing);
  });

  testWidgets('wide workspace shows chat and changeable device frame',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 850);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: WorkshopWebGeneratorWorkspace(
          composer: Center(child: Text('Chat con AIVEXUS')),
        ),
      ),
    ));
    expect(find.text('Chat con AIVEXUS'), findsOneWidget);
    expect(find.text('Nessuna app da visualizzare'), findsOneWidget);
    expect(find.byKey(const Key('web_preview_platform_web')), findsOneWidget);

    await tester.tap(find.byKey(const Key('web_platform_picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('web_platform_option_android')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('web_preview_platform_android')), findsOneWidget);
    expect(find.text('Chat con AIVEXUS'), findsOneWidget);

    await tester.tap(find.byKey(const Key('web_platform_picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('web_platform_option_macos')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('web_preview_platform_macos')), findsOneWidget);
  });

  testWidgets('compact workspace switches between chat and preview',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: WorkshopWebGeneratorWorkspace(
          composer: Center(child: Text('Chat compatta')),
          platform: WorkshopWebTarget.ios,
        ),
      ),
    ));

    expect(find.text('Chat compatta'), findsOneWidget);
    expect(find.text('Nessuna app da visualizzare'), findsNothing);

    await tester.tap(find.text('Anteprima interattiva'));
    await tester.pumpAndSettle();
    expect(find.text('Nessuna app da visualizzare'), findsOneWidget);
    expect(find.byKey(const Key('web_preview_platform_ios')), findsOneWidget);

    await tester.tap(find.text('Richiesta'));
    await tester.pumpAndSettle();
    expect(find.text('Chat compatta'), findsOneWidget);
  });

  test('platform codes are stable and unknown codes fall back to Web', () {
    expect(WorkshopWebTarget.fromCode('android'), WorkshopWebTarget.android);
    expect(WorkshopWebTarget.fromCode('ios'), WorkshopWebTarget.ios);
    expect(WorkshopWebTarget.fromCode('windows'), WorkshopWebTarget.windows);
    expect(WorkshopWebTarget.fromCode('unexpected'), WorkshopWebTarget.web);
  });
}

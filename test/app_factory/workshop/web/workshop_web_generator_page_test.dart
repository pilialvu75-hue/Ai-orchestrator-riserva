import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_generator_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/link.dart';

void main() {
  testWidgets('submits once and recovers a saved generation without the prompt',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(950, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    const prompt = 'Un allenamento a intervalli';
    String? generationId;
    var requests = 0;
    var verificationPosts = 0;
    final client = MockClient((request) async {
      requests++;
      if (request.url.path == '/api/cantiere/proposals/source') {
        expect(request.method, 'GET');
        expect(request.url.queryParameters, {'generationId': generationId});
        return http.Response(
            jsonEncode({
              'version': 1,
              'ok': true,
              'generationId': generationId,
              'sourceSha256': 'a' * 64,
              'source': {
                'files': [
                  {'path': 'index.html', 'content': '<h1>Intervalli</h1>'},
                  {'path': 'timer.mjs', 'content': 'const seconds = 30;'},
                ]
              },
            }),
            200);
      }
      if (request.url.path == '/api/cantiere/proposals/verify') {
        if (request.method == 'GET') {
          expect(request.url.queryParameters, {'generationId': generationId});
          expect(request.body, isEmpty);
        } else {
          expect(request.method, 'POST');
          expect(jsonDecode(request.body), {'generationId': generationId});
          verificationPosts++;
        }
        return http.Response(
            jsonEncode({
              'version': 1,
              'ok': true,
              'generationId': generationId,
              'status': switch (verificationPosts) {
                0 => 'ready',
                1 => 'submitted',
                _ => 'verified',
              },
              if (verificationPosts > 1) 'zipSha256': 'b' * 64,
              if (verificationPosts > 1) 'sourceSha256': 'a' * 64,
            }),
            200);
      }
      expect(request.url.path, '/api/cantiere/proposals/generate');
      if (request.method == 'POST') {
        final submitted = jsonDecode(request.body) as Map;
        expect(submitted['prompt'], prompt);
        generationId = submitted['generationId'] as String;
        return http.Response(
            jsonEncode({
              'version': 1,
              'ok': true,
              'status': 'generating',
              'generationId': generationId,
            }),
            200);
      }
      expect(request.method, 'GET');
      expect(request.url.queryParameters, {'generationId': generationId});
      expect(request.body, isEmpty);
      return http.Response(
          jsonEncode({
            'version': 1,
            'ok': true,
            'status': 'generated',
            'generationId': generationId,
            'title': 'Allenamento a intervalli',
            'requirements': ['Alterna riposo e corsa'],
            'paths': ['index.html', 'timer.mjs'],
            'sourceSha256': 'a' * 64,
            'provenance': {'reportedModel': '@cf/google/gemma-4-26b-a4b-it'},
          }),
          200);
    });

    await tester.pumpWidget(
        MaterialApp(home: WorkshopWebGeneratorPage(client: client)));
    await tester.pumpAndSettle();
    expect(requests, 0);
    expect(find.byKey(const Key('web_generator_first_prompt')), findsOneWidget);
    expect(find.byKey(const Key('web_preview_platform_web')), findsNothing);
    await tester.tap(find.byKey(const Key('web_platform_picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('web_platform_option_android')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('web_generator_first_prompt')), prompt);
    await tester.pump();
    await tester.tap(find.text('Genera'));
    await tester.pumpAndSettle();
    expect(find.text('Generazione in corso'), findsOneWidget);
    expect(requests, 1);
    expect(find.byKey(const Key('web_generator_first_prompt')), findsNothing);
    expect(find.byKey(const Key('web_preview_platform_android')), findsOneWidget);

    final preferences = await SharedPreferences.getInstance();
    expect(
        preferences.getString('aivexus.web.lastGeneration.v1'), generationId);
    expect(preferences.getKeys(), {
      'aivexus.web.lastGeneration.v1',
      'aivexus.web.generationPreviewPlatform.v1',
    });
    expect(preferences.getString('aivexus.web.generationPreviewPlatform.v1'),
        'android');

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
        MaterialApp(home: WorkshopWebGeneratorPage(client: client)));
    await tester.pumpAndSettle();
    expect(requests, 3);
    expect(verificationPosts, 0);
    expect(find.byKey(const Key('web_preview_platform_android')), findsOneWidget);
    expect(find.text('Sorgenti generati'), findsOneWidget);
    expect(find.text('Allenamento a intervalli'), findsOneWidget);
    expect(find.text('timer.mjs'), findsOneWidget);
    expect(find.text('@cf/google/gemma-4-26b-a4b-it'), findsOneWidget);
    expect(find.text(prompt), findsNothing);
    expect(find.text('Scarica ZIP'), findsNothing);

    // The already-verified generator receipt starts verification without
    // requiring the user to press the old manual "Verifica applicazione" button.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(verificationPosts, 1);
    expect(find.text('Verifica in coda o in esecuzione'), findsOneWidget);
    await tester.ensureVisible(find.text('Aggiorna verifica'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aggiorna verifica'));
    await tester.pumpAndSettle();
    expect(verificationPosts, 2);
    expect(find.text('Applicazione verificata'), findsOneWidget);
    final download = tester.widget<Link>(find.byType(Link));
    expect(download.uri?.path, '/api/cantiere/proposals/download');
    expect(download.uri?.queryParameters, {'generationId': generationId});
    expect(find.text('Anteprima'), findsOneWidget);
    await tester.ensureVisible(find.text('Sorgenti'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sorgenti'));
    await tester.pumpAndSettle();
    expect(find.text('Sorgenti verificati'), findsOneWidget);
    expect(find.text('<h1>Intervalli</h1>'), findsOneWidget);
  });
}

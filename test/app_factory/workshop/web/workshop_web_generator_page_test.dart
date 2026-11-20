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
      if (request.url.path == '/api/cantiere/proposals/quota') {
        expect(request.method, 'GET');
        return http.Response(jsonEncode({
          'version': 1, 'ok': true,
          'scope': 'aivexus_reservations',
          'remaining': 10, 'userRemaining': 10, 'userLimit': 10,
          'globalRemaining': 36, 'globalLimit': 36,
          'nextAvailableAt': null,
        }), 200);
      }
      if (request.url.path == '/api/cantiere/proposals/reuse') {
        expect(request.method, 'GET');
        return http.Response(jsonEncode({
          'version': 1, 'ok': true, 'found': false,
        }), 200);
      }
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
    expect(find.byKey(const Key('web_generator_quota_meter')), findsOneWidget);
    expect(find.textContaining('Generazioni disponibili: 10'), findsOneWidget);
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

  testWidgets('long structured first prompt is retained and submitted intact',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1100, 950);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});

    final prompt = List<String>.filled(
      100, 'Requisito: accessibilità e navigazione completa.',
    ).join('\n');
    expect(prompt.length, greaterThan(1200));
    expect(prompt.length, lessThan(8000));
    String? sentPrompt;
    final client = MockClient((request) async {
      if (request.url.path == '/api/cantiere/proposals/quota') {
        expect(request.method, 'GET');
        return http.Response(jsonEncode({
          'version': 1, 'ok': true,
          'scope': 'aivexus_reservations',
          'remaining': 10, 'userRemaining': 10, 'userLimit': 10,
          'globalRemaining': 36, 'globalLimit': 36,
          'nextAvailableAt': null,
        }), 200);
      }
      if (request.url.path == '/api/cantiere/proposals/reuse') {
        return http.Response(jsonEncode({
          'version': 1, 'ok': true, 'found': false,
        }), 200);
      }
      expect(request.method, 'POST');
      expect(request.url.path, '/api/cantiere/proposals/generate');
      sentPrompt = (jsonDecode(request.body) as Map)['prompt'] as String;
      return http.Response(jsonEncode({
        'version': 1,
        'ok': true,
        'generationId': (jsonDecode(request.body) as Map)['generationId'],
        'status': 'generating',
      }), 200);
    });

    await tester.pumpWidget(
      MaterialApp(home: WorkshopWebGeneratorPage(client: client)),
    );
    await tester.pumpAndSettle();
    final editor = find.byKey(const Key('web_generator_first_prompt'));
    expect(tester.widget<TextField>(editor).maxLength, 8000);
    await tester.enterText(editor, prompt);
    await tester.pump();
    expect(tester.widget<TextField>(editor).controller!.text, prompt);
    await tester.tap(find.text('Genera'));
    await tester.pumpAndSettle();

    expect(sentPrompt, prompt);
    expect(find.text('Generazione in corso'), findsOneWidget);
  });


  testWidgets('quota rejection shows remaining zero and a recovery time',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1120, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});

    int quotaReads = 0;
    int generationPosts = 0;
    final next = DateTime.now().toUtc().add(const Duration(minutes: 45));
    final client = MockClient((request) async {
      if (request.url.path == '/api/cantiere/proposals/quota') {
        quotaReads++;
        return http.Response(jsonEncode({
          'version': 1, 'ok': true, 'scope': 'aivexus_reservations',
          'remaining': 0, 'userRemaining': 0, 'userLimit': 10,
          'globalRemaining': 12, 'globalLimit': 36,
          'nextAvailableAt': next.toIso8601String(),
        }), 200);
      }
      if (request.url.path == '/api/cantiere/proposals/reuse') {
        return http.Response(jsonEncode({
          'version': 1, 'ok': true, 'found': false,
        }), 200);
      }
      expect(request.url.path, '/api/cantiere/proposals/generate');
      expect(request.method, 'POST');
      generationPosts++;
      return http.Response(
        jsonEncode({'version': 1, 'ok': false, 'error': 'generation_quota_exceeded'}),
        429,
      );
    });

    await tester.pumpWidget(
      MaterialApp(home: WorkshopWebGeneratorPage(client: client)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Generazioni disponibili: 0'), findsOneWidget);
    expect(find.byKey(const Key('web_generator_quota_next')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('web_generator_first_prompt')),
      'Crea un esempio con tre menu.',
    );
    await tester.pump();
    await tester.tap(find.text('Genera'));
    await tester.pumpAndSettle();

    expect(generationPosts, 1);
    expect(quotaReads, greaterThanOrEqualTo(2));
    expect(find.text('Limite di generazione raggiunto. Riprova più tardi.'),
        findsOneWidget);
    expect(find.textContaining('Generazioni disponibili: 0'), findsOneWidget);
    expect(find.byKey(const Key('web_generator_quota_next')), findsOneWidget);
  });


  testWidgets('verified same-owner prompt reopens previous app without AI generation',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1150, 920);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});

    final preferencesAtStart = await SharedPreferences.getInstance();
    await preferencesAtStart.remove('aivexus.web.lastGeneration.v1');
    const oldId = '11111111-1111-4111-8111-111111111111';
    const prompt = 'Una app per catalogare le mie letture';
    int generationPosts = 0;
    int reuseReads = 0;
    final seenRoutes = <String>[];
    final client = MockClient((request) async {
      seenRoutes.add('${request.method} ${request.url}');
      if (request.url.path == '/api/cantiere/proposals/quota') {
        return http.Response(jsonEncode({
          'version': 1, 'ok': true,
          'scope': 'aivexus_reservations',
          'remaining': 9, 'userRemaining': 9, 'userLimit': 10,
          'globalRemaining': 70, 'globalLimit': 72,
          'nextAvailableAt': null,
        }), 200);
      }
      if (request.url.path == '/api/cantiere/proposals/reuse') {
        expect(request.method, 'GET');
        expect(request.url.queryParameters['promptSha256']?.length, 64);
        reuseReads++;
        return http.Response(jsonEncode({
          'version': 1, 'ok': true, 'found': true,
          'generationId': oldId,
        }), 200);
      }
      if (request.url.path == '/api/cantiere/proposals/generate') {
        if (request.method == 'POST') generationPosts++;
        expect(request.method, 'GET');
        expect(request.url.queryParameters['generationId'], oldId);
        return http.Response(jsonEncode({
          'version': 1, 'ok': true,
          'status': 'generated',
          'generationId': oldId,
          'title': 'Catalogo libri',
          'requirements': ['Aprire e cercare libri'],
          'paths': ['index.html'],
          'sourceSha256': 'a' * 64,
          'provenance': {
            'reportedModel': '@cf/google/gemma-4-26b-a4b-it',
          },
        }), 200);
      }
      expect(request.url.path, '/api/cantiere/proposals/verify');
      expect(request.method, 'GET');
      return http.Response(jsonEncode({
        'version': 1, 'ok': true,
        'status': 'verified', 'generationId': oldId,
        'sourceSha256': 'a' * 64,
        'zipSha256': 'b' * 64,
      }), 200);
    });
    await tester.pumpWidget(
      MaterialApp(home: WorkshopWebGeneratorPage(client: client)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('web_generator_first_prompt')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('web_generator_first_prompt')), prompt);
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilledButton>(
        find.byKey(const Key('web_generator_submit_first_prompt'))).onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const Key('web_generator_submit_first_prompt')));
    await tester.pumpAndSettle();
    expect(generationPosts, 0, reason: seenRoutes.join(' | '));
    expect(reuseReads, 1, reason: seenRoutes.join(' | '));
    expect(generationPosts, 0);
    expect(find.byKey(const Key('web_generator_reused_verified')), findsOneWidget);
    expect(find.text('Catalogo libri'), findsOneWidget);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('aivexus.web.lastGeneration.v1'), oldId);
  });
}

import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_generator_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('generates, polls and dispatches verification automatically once',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 850);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});

    const prompt = 'Una app Web contatore con un bottone';
    String? generationId;
    var generationPosts = 0;
    var statusReads = 0;
    var verifyReads = 0;
    var verifyPosts = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/api/cantiere/proposals/quota') {
        return http.Response(jsonEncode({
          'version': 1, 'ok': true,
          'scope': 'aivexus_reservations',
          'remaining': 10, 'userRemaining': 10, 'userLimit': 10,
          'globalRemaining': 36, 'globalLimit': 36,
          'nextAvailableAt': null,
        }), 200);
      }
      if (request.url.path == '/api/cantiere/proposals/generate') {
        if (request.method == 'POST') {
          generationPosts++;
          final body = jsonDecode(request.body) as Map;
          expect(body['prompt'], prompt);
          generationId = body['generationId'] as String;
          return http.Response(jsonEncode({
            'version': 1,
            'ok': true,
            'generationId': generationId,
            'status': 'generating',
          }), 200);
        }
        expect(request.method, 'GET');
        expect(request.url.queryParameters['generationId'], generationId);
        statusReads++;
        return http.Response(jsonEncode({
          'version': 1,
          'ok': true,
          'generationId': generationId,
          'status': 'generated',
          'title': 'Contatore',
          'requirements': ['Incrementa il conteggio'],
          'paths': ['index.html', 'count.js'],
          'sourceSha256': 'a' * 64,
          'provenance': {'reportedModel': '@cf/google/gemma-4-26b-a4b-it'},
        }), 200);
      }
      expect(request.url.path, '/api/cantiere/proposals/verify');
      if (request.method == 'GET') {
        verifyReads++;
        expect(request.url.queryParameters['generationId'], generationId);
        return http.Response(jsonEncode({
          'version': 1, 'ok': true, 'generationId': generationId,
          'status': 'ready',
        }), 200);
      }
      expect(request.method, 'POST');
      verifyPosts++;
      expect(jsonDecode(request.body)['generationId'], generationId);
      return http.Response(jsonEncode({
        'version': 1, 'ok': true, 'generationId': generationId,
        'status': 'verified',
        'zipSha256': 'b' * 64,
        'sourceSha256': 'a' * 64,
      }), 200);
    });

    await tester.pumpWidget(
      MaterialApp(home: WorkshopWebGeneratorPage(client: client)),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('web_generator_first_prompt')), prompt);
    await tester.pump(); // apply the enabled submit-button state
    await tester.tap(find.text('Genera'));
    await tester.pumpAndSettle();

    expect(generationPosts, 1);
    expect(statusReads, 0);
    expect(find.text('Generazione in corso'), findsOneWidget);

    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(statusReads, 1);
    expect(verifyReads, 1);
    expect(verifyPosts, 0);

    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(verifyPosts, 1);
    expect(find.text('Applicazione verificata'), findsOneWidget);
    expect(find.text('Scarica ZIP'), findsOneWidget);

    // No duplicate generation, repair or runner dispatch after completion.
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(generationPosts, 1);
    expect(verifyPosts, 1);
    expect(statusReads, 1);
  });
}

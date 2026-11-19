import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_generator_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('submits once and recovers a saved generation without the prompt',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    const prompt = 'Un allenamento a intervalli';
    String? generationId;
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
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
    await tester.enterText(find.byType(TextField), prompt);
    await tester.pump();
    await tester.tap(find.text('Genera'));
    await tester.pumpAndSettle();
    expect(find.text('Generazione in corso'), findsOneWidget);
    expect(requests, 1);

    final preferences = await SharedPreferences.getInstance();
    expect(
        preferences.getString('aivexus.web.lastGeneration.v1'), generationId);
    expect(preferences.getKeys(), {'aivexus.web.lastGeneration.v1'});

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
        MaterialApp(home: WorkshopWebGeneratorPage(client: client)));
    await tester.pumpAndSettle();
    expect(requests, 2);
    expect(find.text('Sorgenti generati'), findsOneWidget);
    expect(find.text('Allenamento a intervalli'), findsOneWidget);
    expect(find.text('timer.mjs'), findsOneWidget);
    expect(find.text('@cf/google/gemma-4-26b-a4b-it'), findsOneWidget);
    expect(find.text(prompt), findsNothing);
  });
}

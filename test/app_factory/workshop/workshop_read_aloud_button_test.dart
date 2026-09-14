import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_read_aloud_button.dart';

void main() {
  testWidgets('tap reads the answer once while preparing and allows another tap', (tester) async {
    final done = Completer<void>();
    final texts = <String>[];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      WorkshopReadAloudButton(text: 'Bonjour, voici votre projet.', read: (text) {
        texts.add(text);
        return done.future;
      }),
    )));
    await tester.tap(find.byType(IconButton));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.byType(IconButton));
    expect(texts, ['Bonjour, voici votre projet.']);
    done.complete();
    await tester.pumpAndSettle();
    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    expect(texts.length, 2);
  });

  testWidgets('failure is visible and a subsequent request can retry', (tester) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      WorkshopReadAloudButton(text: 'Risposta', read: (_) async {
        calls++;
        throw StateError('synthesis failed');
      }),
    )));
    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    expect(find.textContaining('Lettura vocale non disponibile'), findsOneWidget);
    await tester.tap(find.byType(IconButton));
    await tester.pump();
    expect(calls, 2);
  });

  testWidgets('closing the view while preparing does not update disposed state', (tester) async {
    final done = Completer<void>();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      WorkshopReadAloudButton(text: 'Risposta', read: (_) => done.future),
    )));
    await tester.tap(find.byType(IconButton));
    await tester.pumpWidget(const SizedBox.shrink());
    done.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_conversation_selection.dart';

void main() {
  testWidgets('Workshop conversation exposes native selection controls',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: WorkshopConversationSelection(
            child: Text('Risposta del Cantiere'),
          ),
        ),
      ),
    );

    expect(find.byType(SelectionArea), findsOneWidget);
    expect(find.text('Risposta del Cantiere'), findsOneWidget);
  });
}

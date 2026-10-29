import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/features/chat/presentation/widgets/chat_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Assistant Markdown table display', () {
    testWidgets('renders a complete pipe table with horizontal scrolling',
        (tester) async {
      const markdown = 'Ecco i valori del PDF:\n\n'
          '| Articolo | Quantità | Prezzo | Codice | Pagina |\n'
          '| --- | ---: | ---: | --- | --- |\n'
          '| Teiera rossa | 1 | 24,00 € | TR-07 | 1/1 |\n'
          '| Tazza blu | 1 | 8,90 € | TZ-19 | 1/1 |\n\n'
          'Fonte: AIVEXUS_Test_PDF_S24.pdf.';
      await tester.pumpWidget(_host(const ChatMessage(
        id: 'table-local',
        sessionId: 'session-table',
        role: 'assistant',
        content: markdown,
        timestamp: 5,
        provider: 'local',
      )));
      expect(find.byType(DataTable), findsOneWidget);
      expect(find.text('Articolo'), findsOneWidget);
      expect(find.text('Quantità'), findsOneWidget);
      expect(find.text('Teiera rossa'), findsOneWidget);
      expect(find.text('Tazza blu'), findsOneWidget);
      expect(find.text('TR-07'), findsOneWidget);
      expect(find.text('TZ-19'), findsOneWidget);
      expect(find.textContaining('Fonte:'), findsOneWidget);
      expect(
        find.byWidgetPredicate((widget) =>
            widget is SingleChildScrollView &&
            widget.scrollDirection == Axis.horizontal),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('preserves normal answers as plain text', (tester) async {
      const answer = 'Quantità:1, Prezzo:8,90 €, Codice: TZ-19.';
      await tester.pumpWidget(_host(const ChatMessage(
        id: 'normal-local',
        sessionId: 'session-table',
        role: 'assistant',
        content: answer,
        timestamp: 5,
        provider: 'local',
      )));
      expect(find.byType(DataTable), findsNothing);
      expect(find.text(answer), findsOneWidget);
    });

    testWidgets('does not render fenced pipe tables', (tester) async {
      const answer = 'Codice esempio:\n'
          '~~~markdown\n'
          '| A | B |\n'
          '| --- | --- |\n'
          '| 1 | 2 |\n'
          '~~~\n'
          'Non è una tabella da visualizzare.';
      await tester.pumpWidget(_host(const ChatMessage(
        id: 'fenced-local',
        sessionId: 'session-table',
        role: 'assistant',
        content: answer,
        timestamp: 5,
        provider: 'local',
      )));
      expect(find.byType(DataTable), findsNothing);
      expect(find.text(answer), findsOneWidget);
    });

    testWidgets('preserves user typed Markdown as original text',
        (tester) async {
      const answer = '| A | B |\n| --- | --- |\n| 1 | 2 |';
      await tester.pumpWidget(_host(const ChatMessage(
        id: 'user-text',
        sessionId: 'session-table',
        role: 'user',
        content: answer,
        timestamp: 5,
      )));
      expect(find.byType(DataTable), findsNothing);
      expect(find.text(answer), findsOneWidget);
    });
  });

  group('ChatBubble Cloud provider label', () {
    testWidgets(
      'shows canonical provider name for pending and final Cloud messages',
      (tester) async {
        await tester.pumpWidget(
          _host(
            const ChatMessage(
              id: 'pending-assistant-1',
              sessionId: 'session-1',
              role: 'assistant',
              content: 'partial response',
              timestamp: 1,
              provider: 'Gemini',
            ),
          ),
        );

        expect(find.text('Gemini'), findsOneWidget);
        expect(find.text('partial response'), findsOneWidget);

        await tester.pumpWidget(
          _host(
            const ChatMessage(
              id: 'assistant-final',
              sessionId: 'session-1',
              role: 'assistant',
              content: 'final response',
              timestamp: 2,
              provider: 'openAi',
            ),
          ),
        );

        expect(find.text('OpenAI'), findsOneWidget);
        expect(find.text('final response'), findsOneWidget);
      },
    );

    testWidgets(
      'does not add a provider label for Local assistant messages',
      (tester) async {
        await tester.pumpWidget(
          _host(
            const ChatMessage(
              id: 'assistant-local',
              sessionId: 'session-1',
              role: 'assistant',
              content: 'local response',
              timestamp: 3,
              provider: 'local',
            ),
          ),
        );

        expect(find.text('local'), findsNothing);
        expect(find.text('Local'), findsNothing);
        expect(find.text('local response'), findsOneWidget);
      },
    );
  });
}

Widget _host(ChatMessage message) {
  return MaterialApp(
    home: Scaffold(
      body: ChatBubble(message: message),
    ),
  );
}

import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/features/chat/presentation/widgets/chat_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

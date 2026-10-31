import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/core/runtime/chat_ui_preferences_service.dart';
import 'package:ai_orchestrator/presentation/chat/components/high_performance_chat_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('user actions match assistant button size and keep edit callback',
      (tester) async {
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    const message = ChatMessage(
      id: 'user-1',
      sessionId: 'test-session',
      role: 'user',
      content: 'Messaggio di prova',
      timestamp: 1,
    );
    ChatMessage? edited;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HighPerformanceChatList(
          controller: scrollController,
          messages: const [message],
          assistantTextSize: AssistantMessageTextSize.medium,
          onEditUserMessage: (value) => edited = value,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final copy = tester.widget<IconButton>(
      find.byWidgetPredicate((widget) =>
          widget is IconButton && widget.tooltip == 'Copia messaggio'),
    );
    final edit = tester.widget<IconButton>(
      find.byWidgetPredicate((widget) =>
          widget is IconButton && widget.tooltip == 'Modifica messaggio'),
    );
    expect(copy.constraints?.minWidth, 40);
    expect(copy.constraints?.minHeight, 40);
    expect(edit.constraints?.minWidth, 40);
    expect(edit.constraints?.minHeight, 40);

    await tester.tap(find.byTooltip('Modifica messaggio'));
    expect(edited, message);
    expect(tester.takeException(), isNull);
  });

  testWidgets('assistant voice and copy remain accessible on small screens',
      (tester) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    const message = ChatMessage(
      id: 'assistant-1',
      sessionId: 'test-session',
      role: 'assistant',
      content: 'Risposta locale.',
      timestamp: 2,
      provider: 'local',
    );
    ChatMessage? spoken;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HighPerformanceChatList(
          controller: scrollController,
          messages: const [message],
          assistantTextSize: AssistantMessageTextSize.medium,
          onSpeakAssistantMessage: (value) => spoken = value,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final voice = tester.widget<IconButton>(
      find.byWidgetPredicate((widget) =>
          widget is IconButton && widget.tooltip == 'Ascolta'),
    );
    final copy = tester.widget<IconButton>(
      find.byWidgetPredicate((widget) =>
          widget is IconButton && widget.tooltip == 'Copia'),
    );
    expect(voice.constraints?.minWidth, 40);
    expect(copy.constraints?.minWidth, 40);
    await tester.tap(find.byTooltip('Ascolta'));
    expect(spoken, message);
    expect(find.text('Risposta locale.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

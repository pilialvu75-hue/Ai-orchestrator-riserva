import 'package:ai_orchestrator/features/chat/presentation/widgets/chat_live_button.dart';
import 'package:ai_orchestrator/features/chat/presentation/widgets/chat_composer_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Live launches in the empty composer without hiding dictation',
      (tester) async {
    var launches = 0;
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 340,
          child: ChatComposerLayout(
            wideDraft: false,
            menuButton: const Icon(Icons.add),
            messageField: TextField(controller: controller),
            voiceButton: const Icon(Icons.mic),
            sendButton: ChatLiveButton(
              enabled: true,
              onPressed: () => launches++,
            ),
          ),
        ),
      ),
    ));
    expect(find.byTooltip('Avvia conversazione Live'), findsOneWidget);
    expect(find.byIcon(Icons.mic), findsOneWidget);
    await tester.tap(find.byTooltip('Avvia conversazione Live'));
    expect(launches, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('busy Live session disables duplicate activation', (tester) async {
    var launches = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatLiveButton(enabled: false, onPressed: () => launches++),
      ),
    ));
    final button = tester.widget<IconButton>(find.byType(IconButton));
    expect(button.onPressed, isNull);
    expect(launches, 0);
  });
}

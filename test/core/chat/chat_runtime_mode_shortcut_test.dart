import 'package:ai_orchestrator/features/chat/presentation/widgets/chat_runtime_mode_shortcut.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('settings icon opens the real-mode-settings callback only',
      (tester) async {
    var settingsOpens = 0;
    var developerTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: ChatRuntimeModeShortcut(
              modeName: 'local',
              settingsTooltip: 'Modalità IA',
              onOpenSettings: () => settingsOpens++,
              onDeveloperTap: () => developerTaps++,
            ),
          ),
        ),
      ),
    );
    expect(find.text('LOCAL'), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('chat-runtime-mode-settings')),
    );
    await tester.pump();
    expect(settingsOpens, 1);
    expect(developerTaps, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('label keeps developer gesture and does not switch routing',
      (tester) async {
    var settingsOpens = 0;
    var developerTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: ChatRuntimeModeShortcut(
              modeName: 'hybrid',
              settingsTooltip: 'AI mode',
              onOpenSettings: () => settingsOpens++,
              onDeveloperTap: () => developerTaps++,
            ),
          ),
        ),
      ),
    );
    expect(find.text('HYBRID'), findsOneWidget);
    await tester.tap(find.byKey(const Key('chat-runtime-mode-label')));
    await tester.pump();
    expect(developerTaps, 1);
    expect(settingsOpens, 0);
    expect(tester.takeException(), isNull);
  });
}

import 'package:ai_orchestrator/features/chat/presentation/widgets/chat_composer_primary_action.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host({
    required bool hasDraft,
    bool loading = false,
    bool liveEnabled = true,
    VoidCallback? live,
    required VoidCallback send,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: ChatComposerPrimaryAction(
            hasDraft: hasDraft,
            isLoading: loading,
            liveEnabled: liveEnabled,
            onLive: live,
            onSend: send,
            sendTooltip: 'Invia',
            emptyTooltip: 'Scrivi un messaggio',
          ),
        ),
      ),
    );
  }

  testWidgets('empty composer shows Live without opening the + menu',
      (tester) async {
    var liveTaps = 0;
    var sends = 0;
    await tester.pumpWidget(host(
      hasDraft: false,
      live: () => liveTaps++,
      send: () => sends++,
    ));
    expect(find.byTooltip('Avvia Live'), findsOneWidget);
    expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);
    await tester.tap(find.byTooltip('Avvia Live'));
    expect(liveTaps, 1);
    expect(sends, 0);
  });

  testWidgets('draft replaces Live with Send in the same slot', (tester) async {
    var sends = 0;
    await tester.pumpWidget(host(
      hasDraft: true,
      live: () => fail('Must not launch Live on a draft'),
      send: () => sends++,
    ));
    expect(find.byTooltip('Avvia Live'), findsNothing);
    expect(find.byTooltip('Invia'), findsOneWidget);
    await tester.tap(find.byTooltip('Invia'));
    expect(sends, 1);
  });

  testWidgets('disabled Live and loading preserve safe old behavior',
      (tester) async {
    await tester.pumpWidget(host(
      hasDraft: false,
      liveEnabled: false,
      live: () => fail('Live unavailable'),
      send: () {},
    ));
    expect(find.byTooltip('Avvia Live'), findsNothing);
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    await tester.pumpWidget(host(
      hasDraft: false,
      loading: true,
      live: () => fail('No Live while busy'),
      send: () {},
    ));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byTooltip('Avvia Live'), findsNothing);
  });
}

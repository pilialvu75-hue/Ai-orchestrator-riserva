import 'package:ai_orchestrator/features/chat/presentation/widgets/chat_session_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host({
    required bool pinned,
    required bool selected,
    required VoidCallback onTap,
    required VoidCallback onLongPress,
  }) {
    return MaterialApp(
      home: Scaffold(
        backgroundColor: const Color(0xFF151515),
        body: SizedBox(
          width: 220,
          child: ChatSessionTile(
            title: 'Conversazione con titolo sufficientemente lungo',
            pinned: pinned,
            selected: selected,
            trailing: IconButton(
              tooltip: 'Azioni conversazione',
              onPressed: () {},
              icon: const Icon(Icons.more_vert),
            ),
            onTap: onTap,
            onLongPress: onLongPress,
          ),
        ),
      ),
    );
  }

  testWidgets('selected row remains legible on a narrow sidebar',
      (tester) async {
    await tester.pumpWidget(host(
      pinned: true,
      selected: true,
      onTap: () {},
      onLongPress: () {},
    ));

    final title = tester.widget<Text>(
      find.text('Conversazione con titolo sufficientemente lungo'),
    );
    expect(title.maxLines, 2);
    expect(title.overflow, TextOverflow.ellipsis);
    expect(find.byIcon(Icons.push_pin), findsOneWidget);
    expect(find.byTooltip('Azioni conversazione'), findsOneWidget);
    expect(
      tester.widgetList<Material>(find.byType(Material)).any(
        (surface) => surface.color == const Color(0xFF23344A),
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('tap and long press preserve separate navigation actions',
      (tester) async {
    var taps = 0;
    var longPresses = 0;
    await tester.pumpWidget(host(
      pinned: false,
      selected: false,
      onTap: () => taps++,
      onLongPress: () => longPresses++,
    ));
    expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget);

    final label = find.text('Conversazione con titolo sufficientemente lungo');
    await tester.tap(label);
    expect(taps, 1);
    expect(longPresses, 0);

    await tester.longPress(label);
    expect(longPresses, 1);
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });
}

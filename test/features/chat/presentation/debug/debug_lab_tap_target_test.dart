import 'package:ai_orchestrator/features/chat/presentation/debug/debug_lab_controller.dart';
import 'package:ai_orchestrator/features/chat/presentation/debug/debug_lab_tap_target.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final width in <double>[360, 1200]) {
    testWidgets('hidden header target opens only on seventh tap at width $width',
        (tester) async {
      final controller = DebugLabController.instance;
      controller.close();
      addTearDown(controller.close);
      await tester.binding.setSurfaceSize(Size(width, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          appBar: AppBar(actions: [
            DebugLabTapTarget(controller: controller),
            PopupMenuButton<int>(
              key: const Key('ordinary-metrics-menu'),
              itemBuilder: (_) => const [
                PopupMenuItem<int>(value: 1, child: Text('Metrics')),
              ],
            ),
          ]),
        ),
      ));
      final target = find.byKey(const Key('aivexus-header-accent'));
      expect(target, findsOneWidget);
      for (var i = 0; i < 6; i++) {
        await tester.tap(target);
        expect(controller.isVisible, isFalse);
      }
      await tester.tap(target);
      expect(controller.isVisible, isTrue);
      controller.close();

      await tester.tap(find.byKey(const Key('ordinary-metrics-menu')));
      await tester.pumpAndSettle();
      expect(find.text('Metrics'), findsOneWidget);
      expect(find.text('Debug Lab'), findsNothing);
      expect(controller.isVisible, isFalse);
    });
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/features/chat/presentation/widgets/android_keyboard_aware_composer.dart';

void main() {
  Future<void> pumpLayout(
    WidgetTester tester, {
    required double keyboardHeight,
    required bool android,
  }) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(size: Size(400, 800)).copyWith(
          viewInsets: EdgeInsets.only(bottom: keyboardHeight),
        ),
        child: Scaffold(
          resizeToAvoidBottomInset: !android,
          body: const Center(child: Text('Conversation')),
          bottomNavigationBar: AndroidKeyboardAwareComposer(
            enabled: android,
            child: const SizedBox(
              key: Key('chat-composer'),
              height: 64,
              child: Center(child: TextField()),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('Android composer stays above visible 300px IME', (tester) async {
    await pumpLayout(tester, keyboardHeight: 300, android: true);
    final composerBottom = tester.getBottomRight(
      find.byKey(const Key('chat-composer')),
    ).dy;
    expect(composerBottom, lessThanOrEqualTo(500));
    expect(tester.getSize(find.byKey(const Key('chat-composer'))).height, 64);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android composer returns to screen bottom after IME closes',
      (tester) async {
    await pumpLayout(tester, keyboardHeight: 300, android: true);
    await pumpLayout(tester, keyboardHeight: 0, android: true);
    final composerBottom = tester.getBottomRight(
      find.byKey(const Key('chat-composer')),
    ).dy;
    expect(composerBottom, 800);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows composer does not use Android inset spacer',
      (tester) async {
    await pumpLayout(tester, keyboardHeight: 0, android: false);
    expect(find.byKey(const Key('android-chat-composer-keyboard-inset')),
        findsNothing);
    expect(tester.takeException(), isNull);
  });
}

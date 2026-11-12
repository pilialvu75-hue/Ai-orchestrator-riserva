import 'package:aivexus_score/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('scores, undo, reset cancellation and confirmation work', (
    tester,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(ScoreApp(store: ScoreStore(preferences)));

    Text score(String key) => tester.widget<Text>(find.byKey(Key(key)));

    expect(score('home-score').data, '0');
    await tester.tap(find.byKey(const Key('home-plus')));
    await tester.pump();
    expect(score('home-score').data, '1');
    await tester.tap(find.byKey(const Key('away-plus')));
    await tester.pump();
    expect(score('away-score').data, '1');

    await tester.ensureVisible(find.byKey(const Key('undo-button')));
    await tester.tap(find.byKey(const Key('undo-button')));
    await tester.pump();
    expect(score('away-score').data, '0');

    await tester.ensureVisible(find.byKey(const Key('reset-button')));
    await tester.tap(find.byKey(const Key('reset-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cancel-reset')));
    await tester.pumpAndSettle();
    expect(score('home-score').data, '1');

    await tester.tap(find.byKey(const Key('reset-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-reset')));
    await tester.pumpAndSettle();
    expect(score('home-score').data, '0');
  });

  testWidgets('player rename is saved locally', (tester) async {
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(ScoreApp(store: ScoreStore(preferences)));
    await tester.tap(find.byKey(const Key('home-rename')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('name-input')), 'Alice');
    await tester.tap(find.byKey(const Key('confirm-name')));
    await tester.pumpAndSettle();
    expect(find.text('Alice'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(ScoreApp(store: ScoreStore(preferences)));
    expect(find.text('Alice'), findsOneWidget);
  });

  testWidgets('score survives widget recreation using local preferences', (
    tester,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(ScoreApp(store: ScoreStore(preferences)));
    await tester.tap(find.byKey(const Key('home-plus')));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(ScoreApp(store: ScoreStore(preferences)));
    expect(
      tester.widget<Text>(find.byKey(const Key('home-score'))).data,
      '1',
    );
  });
}

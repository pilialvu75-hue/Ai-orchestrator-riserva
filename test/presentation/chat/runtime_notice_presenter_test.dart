import 'package:ai_orchestrator/presentation/chat/controllers/runtime_notice_presenter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('desktop chat error floats above composer, leaving input tappable',
      (tester) async {
    final presenter = RuntimeNoticePresenter();
    addTearDown(presenter.dispose);
    late BuildContext chatContext;
    const composerKey = Key('chat-composer');

    // Desktop shell has a parent Scaffold. A chat-local messenger must own
    // the notice, otherwise the parent snackbar overlaps the inner composer.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ScaffoldMessenger(
            child: Scaffold(
              body: Builder(builder: (context) {
                chatContext = context;
                return const Center(child: Text('Chat'));
              }),
              bottomNavigationBar: const SizedBox(
                height: 76,
                child: TextField(key: composerKey),
              ),
            ),
          ),
        ),
      ),
    );

    presenter.update(chatContext, 'Errore di inferenza');
    await tester.pumpAndSettle();

    final snackBar = find.byType(SnackBar);
    expect(snackBar, findsOneWidget);
    expect(tester.widget<SnackBar>(snackBar).behavior,
        SnackBarBehavior.floating);
    expect(
      tester.getBottomLeft(snackBar).dy,
      lessThanOrEqualTo(tester.getTopLeft(find.byKey(composerKey)).dy),
    );
    await tester.enterText(find.byKey(composerKey), 'Posso ancora scrivere');
    expect(find.text('Posso ancora scrivere'), findsOneWidget);
    // The fake async test must release the six-second notice timer before
    // teardown, just like a new chat request clears the runtime notice.
    presenter.update(chatContext, null);
    await tester.pumpAndSettle();
  });

  testWidgets('repeated notices expire once and leave the composer usable', (
    tester,
  ) async {
    final presenter = RuntimeNoticePresenter();
    addTearDown(presenter.dispose);
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (value) {
              context = value;
              return const TextField();
            },
          ),
        ),
      ),
    );
    const error = 'Generazione fermata per pressione sulla memoria.';
    presenter.update(context, error);
    await tester.pumpAndSettle();
    for (var i = 0; i < 20; i++) {
      presenter.update(context, error);
    }
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    expect(find.text(error), findsNothing);
    await tester.enterText(find.byType(TextField), 'Nuova domanda');
    expect(find.text('Nuova domanda'), findsOneWidget);
    // A new request clears notice state; the same later error is shown again.
    presenter.update(context, null);
    presenter.update(context, error);
    await tester.pumpAndSettle();
    expect(find.text(error), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text(error), findsNothing);
  });

  testWidgets('settings action cannot keep a runtime error permanently open', (
    tester,
  ) async {
    final presenter = RuntimeNoticePresenter();
    addTearDown(presenter.dispose);
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(accessibleNavigation: true),
          child: Scaffold(
            body: Builder(
              builder: (value) {
                context = value;
                return const TextField();
              },
            ),
          ),
        ),
      ),
    );
    presenter.update(
      context,
      'Memory error',
      action: SnackBarAction(label: 'Settings', onPressed: () {}),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    expect(find.text('Memory error'), findsNothing);
  });

  testWidgets('new request removes the previous notice', (tester) async {
    final presenter = RuntimeNoticePresenter();
    addTearDown(presenter.dispose);
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (value) {
              context = value;
              return const TextField();
            },
          ),
        ),
      ),
    );
    presenter.update(context, 'Previous error');
    await tester.pumpAndSettle();
    presenter.update(context, null);
    await tester.pumpAndSettle();
    expect(find.text('Previous error'), findsNothing);
  });
}

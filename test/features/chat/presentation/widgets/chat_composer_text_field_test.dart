import 'package:ai_orchestrator/features/chat/presentation/widgets/chat_composer_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('long draft stays intact but the mobile editor stays compact',
      (tester) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final controller = TextEditingController();
    addTearDown(controller.dispose);
    const longDraft =
        'Per addestrare un AI, prima di tutto devi definire chiaramente '
        'il problema o la funzione che deve svolgere. '
        'Questo testo è volutamente lungo: deve rimanere completamente '
        'modificabile anche con font grandi e senza coprire la chat.';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 760),
              textScaler: TextScaler.linear(1.6),
            ),
            child: Center(
              child: SizedBox(
                width: 200,
                child: ChatComposerTextField(
                  controller: controller,
                  enabled: true,
                  autofocus: false,
                  hintText: 'Messaggio...',
                  onSubmitted: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), longDraft);
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.minLines, 1);
    expect(field.maxLines, 2);
    expect(field.scrollPhysics, isA<ClampingScrollPhysics>());
    expect(controller.text, longDraft);
    expect(tester.getSize(find.byType(ChatComposerTextField)).height,
        lessThan(120));
    expect(tester.takeException(), isNull);
  });

  testWidgets('editing a draft and sending keep the original callback',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    String? submitted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposerTextField(
            controller: controller,
            enabled: true,
            autofocus: false,
            hintText: 'Modifica il messaggio...',
            onSubmitted: (text) => submitted = text,
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'Un messaggio di prova');
    expect(controller.text, 'Un messaggio di prova');
    // The composer keeps the multiline keyboard action; submission remains
    // wired to the same callback for the parent Send button.
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.textInputAction, TextInputAction.newline);
    field.onSubmitted?.call(controller.text);
    expect(submitted, 'Un messaggio di prova');
    expect(tester.takeException(), isNull);
  });
}

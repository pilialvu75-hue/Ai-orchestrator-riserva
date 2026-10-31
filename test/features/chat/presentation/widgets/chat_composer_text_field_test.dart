import 'package:ai_orchestrator/features/chat/presentation/widgets/chat_composer_layout.dart';
import 'package:ai_orchestrator/features/chat/presentation/widgets/chat_composer_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('pasted text gets more horizontal room on phone screens',
      (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    const draft = 'Per addestrare un AI prima di tutto devi definire '
        'chiaramente il problema o la funzione che deve svolgere. '
        'Questo testo non deve essere ridotto o cancellato.';
    var menuTaps = 0;
    var voiceTaps = 0;
    var sendTaps = 0;
    Widget host(bool wide) => MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 340,
                child: ChatComposerLayout(
                  wideDraft: wide,
                  menuButton: IconButton(
                    onPressed: () => menuTaps++,
                    icon: const Icon(Icons.add),
                  ),
                  messageField: ChatComposerTextField(
                    controller: controller,
                    enabled: true,
                    autofocus: false,
                    hintText: 'Messaggio...',
                    onSubmitted: (_) {},
                  ),
                  voiceButton: IconButton(
                    onPressed: () => voiceTaps++,
                    icon: const Icon(Icons.mic),
                  ),
                  sendButton: IconButton(
                    onPressed: () => sendTaps++,
                    icon: const Icon(Icons.arrow_upward),
                  ),
                ),
              ),
            ),
          ),
        );
    await tester.pumpWidget(host(false));
    final compact = tester.getSize(find.byType(TextField)).width;
    expect(compact, lessThan(220));

    await tester.pumpWidget(host(true));
    await tester.enterText(find.byType(TextField), draft);
    await tester.pump();
    final expanded = tester.getSize(find.byType(TextField)).width;
    expect(expanded, greaterThan(310));
    expect(expanded, greaterThan(compact + 120));
    expect(controller.text, draft);

    await tester.tap(find.byIcon(Icons.add));
    await tester.tap(find.byIcon(Icons.mic));
    await tester.tap(find.byIcon(Icons.arrow_upward));
    expect(menuTaps, 1);
    expect(voiceTaps, 1);
    expect(sendTaps, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('original five-line input and multiline callback stay intact',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    String? submitted;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatComposerTextField(
          controller: controller,
          enabled: true,
          autofocus: false,
          hintText: 'Modifica il messaggio...',
          onSubmitted: (value) => submitted = value,
        ),
      ),
    ));
    const message = 'Messaggio di prova senza perdita di testo.';
    await tester.enterText(find.byType(TextField), message);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.minLines, 1);
    expect(field.maxLines, 5);
    expect(field.textInputAction, TextInputAction.newline);
    expect(controller.text, message);
    field.onSubmitted?.call(controller.text);
    expect(submitted, message);
    expect(tester.takeException(), isNull);
  });
}

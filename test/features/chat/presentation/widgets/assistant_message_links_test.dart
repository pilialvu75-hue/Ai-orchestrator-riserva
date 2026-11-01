import 'package:ai_orchestrator/features/chat/presentation/widgets/assistant_message_content.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const style = TextStyle(fontSize: 16, color: Colors.white);

  testWidgets('French source links have readable labels and open HTTPS',
      (tester) async {
    final opened = <Uri>[];
    const reply = 'Sources:\n'
        '1. [Footballdatabase.eu](https://www.footballdatabase.eu/fr/match/resume/1022195-paris_sg-auxerre)\n'
        '2. [Histoiredupsg.fr](https://histoiredupsg.fr/auxerre-psg-2-1-310503-coupe-de-france-02-03/)';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AssistantMessageContent(
          content: reply,
          style: style,
          openLink: (uri) async {
            opened.add(uri);
            return true;
          },
        ),
      ),
    ));
    final rich = tester.widget<Text>(find.byType(Text));
    final visible = rich.textSpan!.toPlainText();
    expect(visible, contains('Footballdatabase.eu'));
    expect(visible, contains('Histoiredupsg.fr'));
    expect(visible, isNot(contains('](https://')));
    final links = (rich.textSpan! as TextSpan).children!
        .whereType<TextSpan>()
        .where((span) => span.recognizer is TapGestureRecognizer)
        .toList();
    expect(links.length, 2);
    (links.first.recognizer! as TapGestureRecognizer).onTap?.call();
    await tester.pump();
    expect(opened, [
      Uri.parse('https://www.footballdatabase.eu/fr/match/resume/1022195-paris_sg-auxerre')
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rejects unsafe URLs and preserves code fence contents',
      (tester) async {
    const reply = '[Bad](javascript:alert(1))\n'
        '~~~markdown\n'
        '[Example](https://example.com)\n'
        '~~~\n'
        '[Valid](https://safe.example.org/path)';
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: AssistantMessageContent(content: reply, style: style),
      ),
    ));
    final rich = tester.widget<Text>(find.byType(Text));
    expect(rich.textSpan!.toPlainText(),
        contains('[Bad](javascript:alert(1))'));
    expect(rich.textSpan!.toPlainText(),
        contains('[Example](https://example.com)'));
    final links = (rich.textSpan! as TextSpan).children!
        .whereType<TextSpan>()
        .where((span) => span.recognizer is TapGestureRecognizer)
        .toList();
    expect(links.length, 1);
    expect(links.single.text, 'Valid');
    expect(tester.takeException(), isNull);
  });

  testWidgets('plain text and Markdown tables remain unchanged',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: AssistantMessageContent(
          content: 'Risposta normale senza link.',
          style: style,
        ),
      ),
    ));
    expect(find.text('Risposta normale senza link.'), findsOneWidget);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: AssistantMessageContent(
          content: '| Articolo | Prezzo |\n| --- | --- |\n| Teiera | 24 € |',
          style: style,
        ),
      ),
    ));
    expect(find.byType(DataTable), findsOneWidget);
    expect(find.text('Teiera'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

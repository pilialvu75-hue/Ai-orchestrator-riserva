import 'package:ai_orchestrator/features/chat/presentation/widgets/assistant_message_content.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const style = TextStyle(fontSize: 16, color: Colors.white);

  testWidgets('formats heading, bold and existing source link', (tester) async {
    const message = '## Sintesi\n**Risultato:** 1-2\n'
        'Fonte: [Archivio](https://example.org/match)';
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: AssistantMessageContent(content: message, style: style),
      ),
    ));
    final text = tester.widget<Text>(find.byType(Text));
    final rich = text.textSpan! as TextSpan;
    final visible = rich.toPlainText();
    expect(visible, contains('Sintesi'));
    expect(visible, contains('Risultato: 1-2'));
    expect(visible, isNot(contains('## ')));
    expect(visible, isNot(contains('**')));
    final segments = rich.children!.whereType<TextSpan>().toList();
    expect(segments.any((s) => s.text == 'Sintesi' &&
        s.style?.fontWeight == FontWeight.w700), isTrue);
    expect(segments.any((s) => s.text == 'Risultato:' &&
        s.style?.fontWeight == FontWeight.w700), isTrue);
    expect(segments.any((s) => s.text == 'Archivio' &&
        s.recognizer is TapGestureRecognizer), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('code fences and partial streaming syntax are not formatted',
      (tester) async {
    const raw = '~~~dart\n## non titolo\n**non grassetto**\n'
        '[not link](https://example.org)\n~~~\n'
        'Questa risposta **incompleta';
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: AssistantMessageContent(content: raw, style: style),
      ),
    ));
    expect(find.text(raw), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('plain local text uses standard Text widget', (tester) async {
    const raw = 'Risposta normale senza alcuna formattazione.';
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: AssistantMessageContent(content: raw, style: style),
      ),
    ));
    final text = tester.widget<Text>(find.text(raw));
    expect(text.textSpan, isNull);
    expect(tester.takeException(), isNull);
  });
}

import 'package:ai_orchestrator/features/chat/data/services/chat_local_ocr_layout_formatter.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object> line(String text, int x, int y, int w, int h) => {
  'text': text, 'left': x, 'top': y, 'right': x + w, 'bottom': y + h,
};

void main() {
  test('reorders observed headings after preceding paragraphs by page y', () {
    final shuffled = <Object>[
      line('02 / FRANÇAIS', 20, 170, 140, 17),
      line('Le technicien arrivera jeudi.', 20, 140, 330, 16),
      line('03 / ENGLISH', 20, 270, 130, 17),
      line('01 / ITALIANO', 20, 100, 130, 17),
      line('La teiera rossa è sul tavolo.', 20, 120, 340, 16),
      line('« Où est la théière ? »', 20, 192, 310, 16),
    ];
    final value = ChatLocalOcrLayoutFormatter.reflow(shuffled)!;
    expect(value.indexOf('01 / ITALIANO'), lessThan(value.indexOf('La teiera')));
    expect(value.indexOf('La teiera'), lessThan(value.indexOf('Le technicien')));
    expect(value.indexOf('Le technicien'), lessThan(value.indexOf('02 / FRANÇAIS')));
    expect(value.indexOf('02 / FRANÇAIS'), lessThan(value.indexOf('« Où est')));
    expect(value.indexOf('« Où est'), lessThan(value.indexOf('03 / ENGLISH')));
  });

  test('joins geometrically aligned table cells into their original rows', () {
    final cells = <Object>[
      line('TV-02', 380, 220, 75, 18),
      line('Teiera rossa', 20, 266, 122, 18),
      line('4,50 €', 278, 220, 76, 18),
      line('Tazza blu', 20, 243, 108, 18),
      line('Q.TÀ', 195, 196, 50, 18),
      line('Thé vert', 20, 220, 105, 18),
      line('1', 195, 266, 18, 18),
      line('ARTICOLO', 20, 196, 110, 18),
      line('TR-07', 380, 266, 75, 18),
      line('24,00 €', 278, 266, 76, 18),
      line('1', 195, 243, 18, 18),
      line('8,90 €', 278, 243, 76, 18),
      line('TZ-19', 380, 243, 75, 18),
      line('2', 195, 220, 18, 18),
      line('PREZZO', 278, 196, 76, 18),
      line('CODICE', 380, 196, 75, 18),
    ];
    final value = ChatLocalOcrLayoutFormatter.reflow(cells)!;
    expect(value, contains('ARTICOLO | Q.TÀ | PREZZO | CODICE'));
    expect(value, contains('Thé vert | 2 | 4,50 € | TV-02'));
    expect(value, contains('Tazza blu | 1 | 8,90 € | TZ-19'));
    expect(value, contains('Teiera rossa | 1 | 24,00 € | TR-07'));
  });

  test('preserves OCR characters without hallucinating O versus zero', () {
    final value = ChatLocalOcrLayoutFormatter.reflow([
      line('0CR TEST O/0 I/l', 8, 10, 215, 18),
      line('à é ê ç ñ', 8, 30, 170, 18),
    ]);
    expect(value, contains('0CR TEST O/0 I/l'));
    expect(value, contains('à é ê ç ñ'));
  });

  test('refuses invalid, excessive or unbounded geometry', () {
    expect(ChatLocalOcrLayoutFormatter.reflow(null), isNull);
    expect(ChatLocalOcrLayoutFormatter.reflow([]), isNull);
    expect(ChatLocalOcrLayoutFormatter.reflow([
      {'text': 'Bad', 'left': 80, 'top': 5, 'right': 9, 'bottom': 20},
    ]), isNull);
    expect(ChatLocalOcrLayoutFormatter.reflow(
      List.generate(121, (i) => line('text', 0, i * 20, 20, 12)),
    ), isNull);
  });
}

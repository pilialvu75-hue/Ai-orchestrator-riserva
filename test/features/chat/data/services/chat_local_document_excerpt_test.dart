import 'package:ai_orchestrator/features/chat/data/services/chat_local_document_excerpt.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _Chunk = ({
  String title,
  String text,
  int score,
  int timestamp,
});

_Chunk chunk(String title, String text, {int score = 1}) =>
    (title: title, text: text, score: score, timestamp: 0);

void main() {
  test('S24 PDF table is present even when it occurs after long boilerplate', () {
    final noise = List<String>.generate(
      85, (i) => 'Paragrafo generico $i senza dati sul prezzo.',
    ).join('\n');
    final excerpt = ChatLocalDocumentExcerpt.render(
      'Qual è il prezzo della teiera rossa, la quantità e il codice? Cita la pagina.',
      [
        chunk('AIVEXUS_Test_PDF_S24.pdf', '[Pagina 1/1]\n' + noise),
        chunk('AIVEXUS_Test_PDF_S24.pdf',
            '04 / TABELLA DI CONTROLLO\n'
            'ARTICOLO Q.TÀ PREZZO CODICE\n'
            'Thé vert 2 4,50 € TV-02\n'
            'Tazza blu 1 8,90 € TZ-19\n'
            'Teiera rossa 1 24,00 € TR-07'),
      ],
    );
    expect(excerpt, contains('[Pagina 1/1]'));
    expect(excerpt, contains('AIVEXUS_Test_PDF_S24.pdf'));
    expect(excerpt, contains('Teiera rossa 1 24,00 € TR-07'));
    expect(excerpt, isNot(contains('124,00 €')));
    expect(excerpt, isNot(contains('Pagina 5/6')));
    expect(excerpt.length, lessThanOrEqualTo(
      ChatLocalDocumentExcerpt.maxEvidenceChars,
    ));
  });

  test('keeps observed ambiguous characters verbatim without repair', () {
    final excerpt = ChatLocalDocumentExcerpt.render('codice O/0', [
      chunk('test.pdf', '[Pagina 1/1]\n'
          'Codice OCR-TEST-041; O/0 I/l e 8/B.'),
    ]);
    expect(excerpt, contains('OCR-TEST-041'));
    expect(excerpt, contains('O/0 I/l e 8/B'));
  });

  test('never invents page attribution for multiple observed page markers', () {
    final excerpt = ChatLocalDocumentExcerpt.render('teiera rossa', [
      chunk('multi.pdf', '[Pagina 1/2]\nIntroduzione'),
      chunk('multi.pdf', '[Pagina 2/2]\nTeiera rossa 1 24,00 € TR-07'),
    ]);
    // A unique matching page is not provable from overlapping chunks;
    // do not prepend one of the two pages as a global citation.
    expect(excerpt, isNot(startsWith('[Pagina')));
    expect(excerpt, contains('Teiera rossa 1 24,00 € TR-07'));
  });

  test('deduplicates the same OCR line in overlapping document chunks', () {
    const row = 'Teiera rossa 1 24,00 € TR-07';
    final excerpt = ChatLocalDocumentExcerpt.render('prezzo teiera rossa', [
      chunk('test.pdf', '[Pagina 1/1]\n$row'),
      chunk('test.pdf', '$row\nAltra riga'),
    ]);
    expect(row.allMatches(excerpt), hasLength(1));
  });

  test('never emits more than a bounded excerpt from large documents', () {
    final huge = List.generate(500, (i) =>
      'Riga $i contiene testo documentale molto lungo e ripetitivo.'
    ).join('\n');
    final excerpt = ChatLocalDocumentExcerpt.render('riassumi il documento', [
      chunk('large.pdf', huge),
    ]);
    expect(excerpt, isNotEmpty);
    expect(excerpt.length,
      lessThanOrEqualTo(ChatLocalDocumentExcerpt.maxEvidenceChars));
  });
}

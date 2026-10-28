import 'package:ai_orchestrator/features/chat/data/services/chat_local_image_ocr_enrichment.dart';
import 'package:cantiere_local_image_vision/cantiere_local_image_vision.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.aiorchestrator/local_image_text');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final poster = LocalImageLabelProcessor.fromNative(<Object?>[
    <String, Object>{'label': 'Tableware', 'confidence': 0.91},
    <String, Object>{'label': 'Poster', 'confidence': 0.77},
    <String, Object>{'label': 'Cup', 'confidence': 0.73},
  ]);
  final fruit = LocalImageLabelProcessor.fromNative(<Object?>[
    <String, Object>{'label': 'Food', 'confidence': 0.92},
    <String, Object>{'label': 'Fruit', 'confidence': 0.78},
  ]);
  var count = 0;

  setUp(() {
    count = 0;
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('offline poster OCR returns source text without guessing a teapot',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      count++;
      expect(call.method, 'readText');
      expect(call.arguments, <String, String>{'path': '/private/poster.jpg'});
      return <String, Object>{
        'text': 'AVANT, J’AVAIS LA SCIENCE INFUSE\n'
            'MAIS ÇA C’EST THÉIÈRE...',
        'truncated': false,
      };
    });
    final response = await ChatLocalImageOcrEnrichment(channel: channel).enrich(
      imagePath: '/private/poster.jpg',
      prompt: 'Cosa vedi in questa immagine?',
      labels: poster,
    );
    expect(response.hasText, true);
    expect(response.text, contains('Poster (77%)'));
    expect(response.text, contains('THÉIÈRE'));
    expect(response.text, contains('OCR offline'));
    expect(response.text, isNot(contains('Teapot')));
    expect(response.text,
        isNot(contains('colori, quantità, testo o altri dettagli')));
    expect(count, 1);
  });

  test('no OCR for ordinary fruit photo and generic question', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      count++;
      return <String, Object>{'text': 'Do not use'};
    });
    final response = await ChatLocalImageOcrEnrichment(channel: channel).enrich(
      imagePath: '/private/apple.jpg',
      prompt: 'Cosa vedi in questa immagine?',
      labels: fruit,
    );
    expect(response.hasText, false);
    expect(response.text, fruit.text);
    expect(count, 0);
  });

  test('explicit OCR request reads image even if labels are generic',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      count++;
      return <String, Object>{'text': 'Bonjour!', 'truncated': false};
    });
    final response = await ChatLocalImageOcrEnrichment(channel: channel).enrich(
      imagePath: '/private/apple.jpg',
      prompt: 'Leggi il testo della foto',
      labels: fruit,
    );
    expect(response.hasText, true);
    expect(response.text, contains('Bonjour!'));
    expect(count, 1);
  });

  test('empty OCR keeps categories and reports no detected writing', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      count++;
      return <String, Object>{'text': '   ', 'truncated': false};
    });
    final response = await ChatLocalImageOcrEnrichment(channel: channel).enrich(
      imagePath: '/private/poster.jpg',
      prompt: 'Cosa vedi?',
      labels: poster,
    );
    expect(response.hasText, false);
    expect(response.text, contains('Poster (77%)'));
    expect(response.text, contains('nessuna scritta leggibile'));
    expect(count, 1);
  });

  test('OCR failure never loses otherwise valid image labels', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      count++;
      throw PlatformException(code: 'OCR_MEMORY');
    });
    final response = await ChatLocalImageOcrEnrichment(channel: channel).enrich(
      imagePath: '/private/poster.jpg',
      prompt: '',
      labels: poster,
    );
    expect(response.hasText, false);
    expect(response.text, contains('Tableware (91%)'));
    expect(response.text, contains('OCR locale non riuscita'));
    expect(count, 1);
  });

  test('OCR results are bounded and marked as truncated', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return <String, Object>{
        'text': List<String>.filled(2400, 'X').join(),
        'truncated': false,
      };
    });
    final response = await ChatLocalImageOcrEnrichment(channel: channel).enrich(
      imagePath: '/private/poster.jpg',
      prompt: '',
      labels: poster,
    );
    expect(response.hasText, true);
    expect(response.text, contains('[Testo abbreviato]'));
    expect(response.text, isNot(contains('X' * 1801)));
  });

  test('when native OCR is absent the classifier still works', () async {
    messenger.setMockMethodCallHandler(channel, null);
    final response = await ChatLocalImageOcrEnrichment(channel: channel).enrich(
      imagePath: '/private/poster.jpg',
      prompt: '',
      labels: poster,
    );
    expect(response.hasText, false);
    expect(response.text, contains('Poster (77%)'));
    expect(response.text, contains('OCR locale non disponibile'));
  });
  test('uses native line rectangles to retain table rows, not flat block order',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async => {
      'text': 'CODICE\nTV-02\nThé vert\n2\n4,50 €',
      'layoutLines': [
        {'text': 'CODICE', 'left': 350, 'top': 100, 'right': 405, 'bottom': 118},
        {'text': 'TV-02', 'left': 350, 'top': 125, 'right': 405, 'bottom': 143},
        {'text': 'Thé vert', 'left': 20, 'top': 125, 'right': 130, 'bottom': 143},
        {'text': '2', 'left': 185, 'top': 125, 'right': 198, 'bottom': 143},
        {'text': '4,50 €', 'left': 260, 'top': 125, 'right': 321, 'bottom': 143},
      ],
      'truncated': false,
      'layoutTruncated': false,
    });
    final response = await ChatLocalImageOcrEnrichment(channel: channel).enrich(
      imagePath: '/private/document.jpg',
      prompt: 'Leggi la tabella',
      labels: poster,
    );
    expect(response.hasText, true);
    expect(response.text, contains('Thé vert | 2 | 4,50 € | TV-02'));
  });

  test('malformed native rectangles fall back to original OCR text',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async => {
      'text': 'Testo precedente valido',
      'layoutLines': [
        {'text': 'NO', 'left': -3, 'top': 5, 'right': 8, 'bottom': 16},
      ],
    });
    final response = await ChatLocalImageOcrEnrichment(channel: channel).enrich(
      imagePath: '/private/document.jpg',
      prompt: 'OCR',
      labels: poster,
    );
    expect(response.text, contains('Testo precedente valido'));
    expect(response.text, isNot(contains('\nNO')));
  });

  test('bounded line extraction signals abbreviated text to user', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => {
      'text': 'Testo',
      'layoutLines': [
        {'text': 'Testo', 'left': 1, 'top': 1, 'right': 50, 'bottom': 19},
      ],
      'layoutTruncated': true,
      'truncated': false,
    });
    final response = await ChatLocalImageOcrEnrichment(channel: channel).enrich(
      imagePath: '/private/document.jpg',
      prompt: 'OCR',
      labels: poster,
    );
    expect(response.text, contains('[Testo abbreviato]'));
  });

}

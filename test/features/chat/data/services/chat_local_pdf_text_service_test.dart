import 'package:ai_orchestrator/features/chat/data/services/chat_local_pdf_text_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.aiorchestrator/local_pdf_text');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('native PDF text extracted offline and returned unchanged', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'extractText');
      expect(call.arguments, <String, String>{'path': '/private/manual.pdf'});
      return <String, Object>{
        'text': '[Pagina 1/1]\nLa teiera costa 24,00 €.',
        'pages': 1,
        'textPages': 1,
        'ocrPages': 0,
      };
    });
    final reader = AndroidPdfOfflineTextReader(
      channel: channel, androidSupported: true,
    );
    expect(await reader.readPdf('/private/manual.pdf'),
        '[Pagina 1/1]\nLa teiera costa 24,00 €.');
  });

  test('invalid native PDF response is rejected rather than indexed', () async {
    messenger.setMockMethodCallHandler(channel, (call) async =>
        <String, Object>{'text': '', 'pages': 1});
    final reader = AndroidPdfOfflineTextReader(
      channel: channel, androidSupported: true,
    );
    await expectLater(reader.readPdf('/private/bad.pdf'), throwsStateError);
  });

  test('native errors are surfaced without raw PDF bytes', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(
        code: 'PDF_PAGES',
        message: 'PDF fino a 6 pagine; trovato: 12.',
      );
    });
    final reader = AndroidPdfOfflineTextReader(
      channel: channel, androidSupported: true,
    );
    await expectLater(reader.readPdf('/private/long.pdf'),
        throwsA(isA<StateError>().having(
          (e) => e.toString(), 'message', contains('6 pagine'))));
  });

  test('unsupported platforms never invoke the Android bridge', () async {
    var called = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      called = true;
      return <String, Object>{'text': 'invalid'};
    });
    final reader = AndroidPdfOfflineTextReader(
      channel: channel, androidSupported: false,
    );
    await expectLater(reader.readPdf('/private/manual.pdf'), throwsStateError);
    expect(called, isFalse);
  });
}

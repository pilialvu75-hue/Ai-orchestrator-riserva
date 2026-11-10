import 'package:ai_orchestrator/core/tools/search/assistant_public_web_link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('extracts only one public HTTPS page from current user input', () {
    final link = AssistantPublicWebLink.fromUserMessage(
      'leggi https://www.example.com/articles/hello?lang=it#chapter-2',
    );
    expect(link?.url.toString(),
        'https://www.example.com/articles/hello?lang=it');
    expect(link?.url.host, 'www.example.com');
  });

  test('rejects YouTube, local/internal endpoints and unsafe schemes', () {
    const invalid = <String>[
      'https://youtube.com/watch?v=hZdi0JUEFSc',
      'https://youtu.be/hZdi0JUEFSc',
      'https://localhost/admin',
      'https://router.home.arpa/',
      'https://printer.local/status',
      'https://local.localhost/',
      'http://example.com/article',
      'https://user:password@example.com/',
      'https://example.com:8080/',
      'ftp://example.com/article',
      'not a URL',
      'https://example.com/one https://example.org/two',
    ];
    for (final input in invalid) {
      expect(AssistantPublicWebLink.fromUserMessage(input), isNull,
          reason: input);
    }
  });

  test('normalizes punctuation around user pasted page links', () {
    final result = AssistantPublicWebLink.fromUserMessage(
      'Fonte: https://www.example.com/story.',
    );
    expect(result?.url.toString(), 'https://www.example.com/story');
  });

  test('bounds link processing for oversized user messages', () {
    expect(
      AssistantPublicWebLink.fromUserMessage(
        List<String>.filled(4097, 'A').join() + ' https://www.example.com/story',
      ),
      isNull,
    );
  });
}

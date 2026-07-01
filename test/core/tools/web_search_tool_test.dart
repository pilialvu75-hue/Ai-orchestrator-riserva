import 'dart:async';
import 'dart:convert';

import 'package:ai_orchestrator/core/tools/web_search_tool.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class _FakeClient extends http.BaseClient {
  _FakeClient(this._handler);

  final Future<http.Response> Function(http.BaseRequest request) _handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _handler(request);
    return http.StreamedResponse(
      Stream.value(utf8.encode(response.body)),
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  }
}

void main() {
  test('estrae con successo i contesti di ricerca dal markup DuckDuckGo HTML', () async {
    final client = _FakeClient((request) async {
      expect(request.url.host, 'html.duckduckgo.com');
      
      // Simulazione del markup HTML reale restituito dall'endpoint leggero
      final mockHtml = '''
      <html>
        <body>
          <div class="web-result">
            <div class="result__body">
              <a class="result__url" href="https://flutter.dev">Flutter - Build apps</a>
              <a class="result__snippet" href="https://flutter.dev">A UI toolkit for building beautiful apps.</a>
            </div>
          </div>
        </body>
      </html>
      ''';

      return http.Response(mockHtml, 200);
    });

    final tool = WebSearchTool(client: client);  
    final result = await tool.execute(<String, dynamic>{'query': 'flutter'});  

    expect(result.success, isTrue);  
    expect(result.output, contains('Query: flutter'));  
    expect(result.output, contains('Flutter - Build apps'));  
    expect(result.output, contains('https://flutter.dev'));
    expect(result.output, contains('A UI toolkit for building beautiful apps.'));
  });
}

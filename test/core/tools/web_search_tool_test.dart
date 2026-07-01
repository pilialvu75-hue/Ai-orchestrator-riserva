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
  test('returns compact search context from DuckDuckGo JSON', () async {
    final client = _FakeClient((request) async {
      expect(request.url.host, 'api.duckduckgo.com');
      return http.Response(
        jsonEncode(
          <String, dynamic>{
            'Heading': 'Flutter',
            'AbstractText': 'A UI toolkit.',
            'AbstractURL': 'https://flutter.dev',
            'RelatedTopics': [
              <String, dynamic>{
                'Text': 'Flutter - Build apps',
                'FirstURL': 'https://flutter.dev',
              },
            ],
          },
        ),
        200,
      );
    });

    final tool = WebSearchTool(client: client);
    final result = await tool.execute(<String, dynamic>{'query': 'flutter'});

    expect(result.success, isTrue);
    expect(result.output, contains('Query: flutter'));
    expect(result.output, contains('Flutter'));
    expect(result.output, contains('https://flutter.dev'));
  });
}

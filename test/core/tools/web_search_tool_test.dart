import 'dart:convert';

import 'package:ai_orchestrator/core/tools/web_search_tool.dart';
import 'package:ai_orchestrator/core/tools/search/search_cache.dart';
import 'package:ai_orchestrator/core/tools/search/search_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
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

class _FakeSearchProvider implements SearchProvider {
  _FakeSearchProvider(this._results);

  final List<SearchResult> _results;
  var calls = 0;

  @override
  Duration get timeout => const Duration(seconds: 5);

  @override
  Future<List<SearchResult>> search(String query, {int limit = 5}) async {
    calls++;
    return _results.take(limit).toList(growable: false);
  }
}

void main() {
  test('returns compact search context from DuckDuckGo JSON', () async {
    RuntimeEventLog.instance.clear();
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
    expect(
      RuntimeEventLog.instance.entries.any(
        (entry) => entry.message.contains('[WEBSEARCH_CACHE_MISS]'),
      ),
      isTrue,
    );
  });

  test('reuses cached search results', () async {
    RuntimeEventLog.instance.clear();
    final provider = _FakeSearchProvider(
      const [
        SearchResult(
          title: 'Cached result',
          url: 'https://example.com',
          snippet: 'Cached snippet',
        ),
      ],
    );
    final cache = InMemorySearchCache();
    final tool = WebSearchTool(
      searchProvider: provider,
      searchCache: cache,
    );

    final first = await tool.execute(<String, dynamic>{'query': 'flutter'});
    final second = await tool.execute(<String, dynamic>{'query': 'flutter'});

    expect(first.success, isTrue);
    expect(second.success, isTrue);
    expect(provider.calls, 1);
    expect(
      RuntimeEventLog.instance.entries.any(
        (entry) => entry.message.contains('[WEBSEARCH_CACHE_HIT]'),
      ),
      isTrue,
    );
  });
}

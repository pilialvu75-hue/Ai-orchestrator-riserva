import 'dart:async';
import 'dart:convert';

import 'package:ai_orchestrator/core/tools/web_search_tool.dart';
import 'package:ai_orchestrator/core/tools/search/search_cache.dart';
import 'package:ai_orchestrator/core/tools/search/assistant_public_web_link.dart';
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

class _ThrowingSearchProvider implements SearchProvider {
  const _ThrowingSearchProvider(this.error);

  final Object error;

  @override
  Duration get timeout => const Duration(seconds: 5);

  @override
  Future<List<SearchResult>> search(String query, {int limit = 5}) async {
    throw error;
  }
}

class _RecordingPublicReader implements AssistantPublicWebReader {
  final urls = <String>[];
  final bool unavailable;

  _RecordingPublicReader({this.unavailable = false});

  @override
  Future<AssistantPublicWebExcerpt?> read(AssistantPublicWebLink link) async {
    urls.add(link.url.toString());
    if (unavailable) return null;
    return AssistantPublicWebExcerpt(
      host: link.url.host,
      text: 'Synthetic dated evidence from ${link.url.host}.',
    );
  }
}

void main() {
  test('Assistant opens ranked public pages rather than only returning links', () async {
    final provider = _FakeSearchProvider(const [
      SearchResult(title: 'Generic calendar', url: 'https://example.com/calendar',
        snippet: 'Generic calendar with no date'),
      SearchResult(title: 'Same publisher', url: 'https://www.example.com/other',
        snippet: 'Duplicate host'),
      SearchResult(title: 'Tracking URL', url: 'https://example.net/?token=private',
        snippet: 'Must not open'),
      SearchResult(title: 'Local endpoint', url: 'https://localhost/status',
        snippet: 'Must not open'),
      SearchResult(title: 'Independent page', url: 'https://example.org/article',
        snippet: 'Generic article'),
      SearchResult(title: 'Third source', url: 'https://example.edu/news',
        snippet: 'Beyond read budget'),
    ]);
    final reader = _RecordingPublicReader();
    final tool = WebSearchTool(searchProvider: provider, publicSourceReader: reader);
    final result = await tool.execute({'query': 'current public fact', 'limit': 6});
    expect(result.success, isTrue);
    expect(reader.urls, [
      'https://example.com/calendar', 'https://example.org/article',
    ]);
    expect(result.metadata['source_pages_read'], 2);
    expect(result.output, contains('Synthetic dated evidence from example.org'));
    expect(result.output, contains('retrieval alone does not establish accuracy'));
    expect(result.output, contains('Generic calendar with no date'));
  });

  test('failed page reading is distinguished from successful search discovery', () async {
    final provider = _FakeSearchProvider(const [
      SearchResult(title: 'Calendar', url: 'https://example.com/calendar',
        snippet: 'No specific date'),
    ]);
    final reader = _RecordingPublicReader(unavailable: true);
    final result = await WebSearchTool(searchProvider: provider,
      publicSourceReader: reader).execute({'query': 'current public fact'});
    expect(result.success, isTrue);
    expect(result.metadata['source_pages_read'], 0);
    expect(result.output, contains('0 page excerpt(s) retrieved'));
    expect(result.output, contains('No specific date'));
  });

  test('automatic source admission rejects unsafe or query-bearing destinations', () {
    for (final url in [
      'http://example.org/article', 'https://localhost/status',
      'https://user:pass@example.org/article',
      'https://example.org:8443/article',
      'https://example.org/?private=1',
      'https://example.org/a https://example.net/b',
    ]) {
      expect(AssistantPublicWebLink.fromSearchResult(url), isNull, reason: url);
    }
    expect(AssistantPublicWebLink.fromSearchResult('https://example.org/article'),
      isNotNull);
  });

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

  test('privacy mode redacts provider exception from logs and tool error',
      () async {
    RuntimeEventLog.instance.clear();
    const secret = 'private-search-term-987654';
    final provider = _ThrowingSearchProvider(
      StateError('failed https://example.test/search?q=$secret'),
    );
    final tool = WebSearchTool(
      searchProvider: provider,
      includeErrorDetailsInDiagnostics: false,
    );

    final result = await tool.execute(<String, dynamic>{'query': secret});
    final diagnostics = RuntimeEventLog.instance.entries
        .map((entry) => entry.message)
        .join('\n');

    expect(result.success, isFalse);
    expect(result.error, 'Web search failed.');
    expect(result.error, isNot(contains(secret)));
    expect(diagnostics, isNot(contains(secret)));
    expect(diagnostics, isNot(contains('example.test')));
    expect(diagnostics, contains('error_type=StateError'));
  });

  test('privacy mode redacts timeout details from logs and tool error',
      () async {
    RuntimeEventLog.instance.clear();
    const secret = 'timeout-private-query-112233';
    final provider = _ThrowingSearchProvider(
      TimeoutException('timeout https://example.test/search?q=$secret'),
    );
    final tool = WebSearchTool(
      searchProvider: provider,
      includeErrorDetailsInDiagnostics: false,
    );

    final result = await tool.execute(<String, dynamic>{'query': secret});
    final diagnostics = RuntimeEventLog.instance.entries
        .map((entry) => entry.message)
        .join('\n');

    expect(result.success, isFalse);
    expect(result.error, 'Web search timed out.');
    expect(result.error, isNot(contains(secret)));
    expect(diagnostics, isNot(contains(secret)));
    expect(diagnostics, isNot(contains('example.test')));
    expect(diagnostics, contains('error_type=TimeoutException'));
  });
}

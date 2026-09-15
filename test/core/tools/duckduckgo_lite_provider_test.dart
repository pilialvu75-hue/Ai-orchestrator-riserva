import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:ai_orchestrator/core/tools/search/duckduckgo_lite_provider.dart';
import 'package:ai_orchestrator/core/tools/search/fallback_search_provider.dart';
import 'package:ai_orchestrator/core/tools/search/search_provider.dart';

class _FakeClient extends http.BaseClient {
  _FakeClient(this._handler);

  final Future<http.Response> Function(http.BaseRequest request) _handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _handler(request);
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(response.body)),
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  }
}

class _FakeProvider implements SearchProvider {
  _FakeProvider({
    this.results = const <SearchResult>[],
    this.error,
    this.providerTimeout = const Duration(seconds: 1),
  });

  final List<SearchResult> results;
  final Object? error;
  final Duration providerTimeout;
  int calls = 0;

  @override
  Duration get timeout => providerTimeout;

  @override
  Future<List<SearchResult>> search(String query, {int limit = 5}) async {
    calls++;
    if (error != null) throw error!;
    return results.take(limit).toList(growable: false);
  }
}

void main() {
  group('DuckDuckGoLiteProvider', () {
    test('parses ranked Lite results without an API key', () async {
      final client = _FakeClient((request) async {
        expect(request.url.host, 'lite.duckduckgo.com');
        expect(request.url.queryParameters['q'], 'latest flutter release');
        expect(request.headers['user-agent'], contains('AI-Orchestrator'));
        expect(request.headers.containsKey('accept-language'), isFalse);

        return http.Response(
          '''
<html><body><table>
<tr>
  <td>1.</td>
  <td>
    <a rel="nofollow" class="result-link" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fflutter.dev%2Freleases">
      Flutter &amp; Dart releases
    </a>
  </td>
</tr>
<tr><td class="result-snippet">Current <b>stable</b> Flutter release information.</td></tr>
<tr>
  <td>2.</td>
  <td><a href="https://dart.dev/" class="result-link">Dart &#39;language&#39;</a></td>
</tr>
<tr><td class="result-snippet">Official Dart website.</td></tr>
</table></body></html>
''',
          200,
          headers: const <String, String>{'content-type': 'text/html'},
        );
      });

      final provider = DuckDuckGoLiteProvider(client: client);
      final results = await provider.search('latest flutter release', limit: 2);

      expect(results, hasLength(2));
      expect(results.first.title, 'Flutter & Dart releases');
      expect(results.first.url, 'https://flutter.dev/releases');
      expect(results.first.snippet, 'Current stable Flutter release information.');
      expect(results[1].title, "Dart 'language'");
      expect(results[1].url, 'https://dart.dev/');
      expect(results[1].snippet, 'Official Dart website.');
    });

    test('returns an empty list when Lite has no parseable results', () async {
      final client = _FakeClient(
        (_) async => http.Response('<html><body>No matches</body></html>', 200),
      );

      final provider = DuckDuckGoLiteProvider(client: client);
      final results = await provider.search('unlikely query');

      expect(results, isEmpty);
    });

    test('rejects challenge pages so a fallback provider can take over',
        () async {
      final client = _FakeClient(
        (_) async => http.Response(
          '<html><body>CAPTCHA unusual traffic challenge-form</body></html>',
          200,
        ),
      );

      final provider = DuckDuckGoLiteProvider(client: client);

      await expectLater(
        provider.search('flutter'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('FallbackSearchProvider', () {
    const fallbackResult = SearchResult(
      title: 'Fallback',
      url: 'https://example.test/fallback',
      snippet: 'Fallback result',
    );

    test('uses primary results without calling fallback', () async {
      final primary = _FakeProvider(
        results: const <SearchResult>[
          SearchResult(
            title: 'Primary',
            url: 'https://example.test/primary',
            snippet: 'Primary result',
          ),
        ],
      );
      final fallback = _FakeProvider(results: const <SearchResult>[fallbackResult]);
      final provider = FallbackSearchProvider(
        primary: primary,
        fallback: fallback,
      );

      final results = await provider.search('query');

      expect(results.single.title, 'Primary');
      expect(primary.calls, 1);
      expect(fallback.calls, 0);
    });

    test('falls back when primary returns no results', () async {
      final primary = _FakeProvider();
      final fallback = _FakeProvider(results: const <SearchResult>[fallbackResult]);
      final provider = FallbackSearchProvider(
        primary: primary,
        fallback: fallback,
      );

      final results = await provider.search('query');

      expect(results.single, fallbackResult);
      expect(primary.calls, 1);
      expect(fallback.calls, 1);
    });

    test('falls back when primary throws', () async {
      final primary = _FakeProvider(error: StateError('primary failed'));
      final fallback = _FakeProvider(results: const <SearchResult>[fallbackResult]);
      final provider = FallbackSearchProvider(
        primary: primary,
        fallback: fallback,
      );

      final results = await provider.search('query');

      expect(results.single, fallbackResult);
      expect(primary.calls, 1);
      expect(fallback.calls, 1);
    });

    test('fails only after both providers fail', () async {
      final primary = _FakeProvider(error: StateError('primary failed'));
      final fallback = _FakeProvider(error: StateError('fallback failed'));
      final provider = FallbackSearchProvider(
        primary: primary,
        fallback: fallback,
      );

      await expectLater(
        provider.search('query'),
        throwsA(isA<StateError>()),
      );
      expect(primary.calls, 1);
      expect(fallback.calls, 1);
    });
  });
}

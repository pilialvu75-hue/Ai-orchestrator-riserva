import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/core/tools/search/search_provider.dart';
import 'package:ai_orchestrator/core/tools/web_search_tool.dart';

void main() {
  test('keeps textual output while exposing structured search results', () async {
    final provider = _FixedSearchProvider(
      const <SearchResult>[
        SearchResult(
          title: 'Recipe app review',
          url: 'https://example.com/review',
          snippet: 'Users value meal planning and shopping lists.',
        ),
        SearchResult(
          title: 'Recipe UX guide',
          url: 'https://example.org/ux',
          snippet: 'Filtering and clear ingredient steps improve usability.',
        ),
      ],
    );
    final tool = WebSearchTool(
      searchProvider: provider,
      includeErrorDetailsInDiagnostics: false,
    );

    final result = await tool.execute(<String, dynamic>{
      'query': 'best recipe apps',
      'limit': 2,
    });

    expect(result.success, isTrue);
    expect(result.output, contains('1. Recipe app review'));
    expect(result.output, contains('URL: https://example.com/review'));
    expect(result.output, contains('2. Recipe UX guide'));

    final results = result.metadata['results'];
    expect(results, isA<List<Object?>>());
    final structured = results! as List<Object?>;
    expect(structured, hasLength(2));

    expect(
      structured[0],
      <String, Object?>{
        'title': 'Recipe app review',
        'url': 'https://example.com/review',
        'snippet': 'Users value meal planning and shopping lists.',
      },
    );
    expect(
      structured[1],
      <String, Object?>{
        'title': 'Recipe UX guide',
        'url': 'https://example.org/ux',
        'snippet': 'Filtering and clear ingredient steps improve usability.',
      },
    );

    // The user query remains part of the existing textual result consumed by
    // models, but is intentionally not duplicated into machine-readable
    // metadata used for source-opening workflows.
    expect(result.metadata.containsKey('query'), isFalse);
  });

  test('distinguishes no results from a provider/network failure', () async {
    final noResultsTool = WebSearchTool(
      searchProvider: _FixedSearchProvider(const <SearchResult>[]),
      includeErrorDetailsInDiagnostics: false,
    );
    final noResults = await noResultsTool.execute(<String, dynamic>{
      'query': 'best recipe apps',
    });

    expect(noResults.success, isFalse);
    expect(noResults.metadata['failure_reason'], 'no_results');
    expect(noResults.metadata.containsKey('query'), isFalse);

    final failedTool = WebSearchTool(
      searchProvider: _FailingSearchProvider(),
      includeErrorDetailsInDiagnostics: false,
    );
    final failed = await failedTool.execute(<String, dynamic>{
      'query': 'best recipe apps',
    });

    expect(failed.success, isFalse);
    expect(failed.metadata['failure_reason'], 'failure');
    expect(failed.metadata.containsKey('query'), isFalse);
  });
}

final class _FixedSearchProvider implements SearchProvider {
  _FixedSearchProvider(this.results);

  final List<SearchResult> results;

  @override
  Duration get timeout => const Duration(seconds: 1);

  @override
  Future<List<SearchResult>> search(String query, {int limit = 5}) async {
    expect(query, 'best recipe apps');
    return results;
  }
}

final class _FailingSearchProvider implements SearchProvider {
  @override
  Duration get timeout => const Duration(seconds: 1);

  @override
  Future<List<SearchResult>> search(String query, {int limit = 5}) async {
    throw StateError('simulated provider failure');
  }
}

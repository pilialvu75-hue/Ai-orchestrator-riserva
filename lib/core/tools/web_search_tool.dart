import 'dart:async';

import 'package:http/http.dart' as http;

import 'package:ai_orchestrator/core/tools/tool.dart';
import 'package:ai_orchestrator/core/tools/search/duckduckgo_provider.dart';
import 'package:ai_orchestrator/core/tools/search/search_cache.dart';
import 'package:ai_orchestrator/core/tools/search/search_provider.dart';

class WebSearchTool implements Tool {
  WebSearchTool({
    http.Client? client,
    SearchProvider? searchProvider,
    SearchCache? searchCache,
    this.maxResults = 5,
    Duration timeout = const Duration(seconds: 5),
  })  : _searchProvider = searchProvider ??
            DuckDuckGoProvider(
              client: client ?? http.Client(),
              timeout: timeout,
            ),
        _searchCache = searchCache;

  final SearchProvider _searchProvider;
  final SearchCache? _searchCache;
  final int maxResults;

  @override
  String get id => 'web_search';

  @override
  String get name => 'Web Search';

  @override
  String get description =>
      'Fetches fresh public web search context from DuckDuckGo and returns '
      'a compact, citation-friendly result summary for local inference.';

  @override
  Future<ToolResult> execute(Map<String, dynamic> params) async {
    final query = (params['query'] as String?)?.trim() ?? '';
    final requestedLimit = (params['limit'] as num?)?.toInt() ?? maxResults;
    final limit = requestedLimit.clamp(1, searchResultsLimit);

    if (query.isEmpty) {
      return const ToolResult(
        toolId: 'web_search',
        output: '',
        success: false,
        error: 'A non-empty "query" parameter is required.',
      );
    }

    try {
      final cached = _searchCache?.get(query);
      final results = cached ??
          await _searchProvider.search(
            query,
            limit: searchResultsLimit,
          ).timeout(
            _searchProvider.timeout,
            onTimeout: () {
              throw TimeoutException(
                'Web search timed out after ${_searchProvider.timeout.inSeconds}s.',
              );
            },
          );
      if (_searchCache != null && cached == null) {
        _searchCache.put(query, results);
      }

      if (results.isEmpty) {
        return ToolResult(
          toolId: id,
          output: 'No search results found for "$query".',
          success: false,
          error: 'No search results found.',
        );
      }

      final limited = results.take(limit);
      final buffer = StringBuffer()
        ..writeln('Query: $query')
        ..writeln('Top results:');
      var index = 1;
      for (final result in limited) {
        buffer
          ..writeln('$index. ${result.title}')
          ..writeln('   URL: ${result.url}')
          ..writeln('   Snippet: ${result.snippet}')
          ..writeln();
        index++;
      }

      return ToolResult(
        toolId: id,
        output: buffer.toString().trimRight(),
        success: true,
      );
    } on TimeoutException catch (error) {
      return ToolResult(
      toolId: id,
      output: '',
      success: false,
      error: 'Web search timed out: $error',
      );
    } catch (error) {
      return ToolResult(
      toolId: id,
        output: '',
        success: false,
        error: 'Web search failed: $error',
      );
    }
  }
}

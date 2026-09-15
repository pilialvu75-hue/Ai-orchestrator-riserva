import 'dart:async';

import 'package:http/http.dart' as http;

import 'package:ai_orchestrator/core/tools/tool.dart';
import 'package:ai_orchestrator/core/tools/search/duckduckgo_provider.dart';
import 'package:ai_orchestrator/core/tools/search/search_cache.dart';
import 'package:ai_orchestrator/core/tools/search/search_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';

class WebSearchTool implements Tool {
  WebSearchTool({
    http.Client? client,
    SearchProvider? searchProvider,
    SearchCache? searchCache,
    this.maxResults = 5,
    this.includeErrorDetailsInDiagnostics = true,
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

  /// Existing callers keep detailed diagnostics by default. Assistant can turn
  /// this off so provider exceptions cannot copy a query-bearing URL into the
  /// runtime log or the user-visible tool error.
  final bool includeErrorDetailsInDiagnostics;

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
    RuntimeEventLog.instance.emit(
      '[WEBSEARCH_ENTER] query_chars=${query.length} limit=$limit',
    );

    if (query.isEmpty) {
      RuntimeEventLog.instance.emit(
        '[WEBSEARCH_EXIT] success=false reason=empty_query',
      );
      return const ToolResult(
        toolId: 'web_search',
        output: '',
        success: false,
        error: 'A non-empty "query" parameter is required.',
        metadata: <String, Object?>{'failure_reason': 'empty_query'},
      );
    }

    try {
      final cached = _searchCache?.get(query);
      RuntimeEventLog.instance.emit(
        cached != null
            ? '[WEBSEARCH_CACHE_HIT] query_chars=${query.length}'
            : '[WEBSEARCH_CACHE_MISS] query_chars=${query.length}',
      );
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
        RuntimeEventLog.instance.emit(
          '[WEBSEARCH_RESULTS_RECEIVED] count=0 empty=true',
        );
        RuntimeEventLog.instance.emit(
          '[WEBSEARCH_EXIT] success=false reason=no_results',
        );
        return ToolResult(
          toolId: id,
          output: '',
          success: false,
          error: 'No search results found.',
          metadata: const <String, Object?>{'failure_reason': 'no_results'},
        );
      }

      final limited = results.take(limit).toList(growable: false);
      RuntimeEventLog.instance.emit(
        '[WEBSEARCH_RESULTS_RECEIVED] count=${results.length} empty=false',
      );
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

      RuntimeEventLog.instance.emit(
        '[WEBSEARCH_EXIT] success=true results=${results.length}',
      );
      return ToolResult(
        toolId: id,
        output: buffer.toString().trimRight(),
        success: true,
        metadata: <String, Object?>{
          'results': limited
              .map(
                (result) => <String, Object?>{
                  'title': result.title,
                  'url': result.url,
                  'snippet': result.snippet,
                },
              )
              .toList(growable: false),
        },
      );
    } on TimeoutException catch (error) {
      RuntimeEventLog.instance.emit(
        includeErrorDetailsInDiagnostics
            ? '[WEBSEARCH_EXIT] success=false reason=timeout error=$error'
            : '[WEBSEARCH_EXIT] success=false reason=timeout '
                'error_type=${error.runtimeType}',
      );
      return ToolResult(
        toolId: id,
        output: '',
        success: false,
        error: includeErrorDetailsInDiagnostics
            ? 'Web search timed out: $error'
            : 'Web search timed out.',
        metadata: const <String, Object?>{'failure_reason': 'timeout'},
      );
    } catch (error) {
      RuntimeEventLog.instance.emit(
        includeErrorDetailsInDiagnostics
            ? '[WEBSEARCH_EXIT] success=false reason=failure error=$error'
            : '[WEBSEARCH_EXIT] success=false reason=failure '
                'error_type=${error.runtimeType}',
      );
      return ToolResult(
        toolId: id,
        output: '',
        success: false,
        error: includeErrorDetailsInDiagnostics
            ? 'Web search failed: $error'
            : 'Web search failed.',
        metadata: const <String, Object?>{'failure_reason': 'failure'},
      );
    }
  }
}

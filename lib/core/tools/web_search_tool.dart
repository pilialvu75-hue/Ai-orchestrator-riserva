import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:ai_orchestrator/core/tools/tool.dart';

class WebSearchTool implements Tool {
  WebSearchTool({
    http.Client? client,
    this.maxResults = 5,
    this.timeout = const Duration(seconds: 5),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final int maxResults;
  final Duration timeout;

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
    final limit = requestedLimit.clamp(1, 8).toInt();

    if (query.isEmpty) {
      return const ToolResult(
        toolId: 'web_search',
        output: '',
        success: false,
        error: 'A non-empty "query" parameter is required.',
      );
    }

    try {
      final uri = Uri.https(
        'api.duckduckgo.com',
        '/',
        <String, String>{
          'q': query,
          'format': 'json',
          'no_html': '1',
          'skip_disambig': '1',
          'no_redirect': '1',
        },
      );
      final response = await _client.get(uri).timeout(
        timeout,
        onTimeout: () {
          throw TimeoutException(
            'DuckDuckGo request timed out after ${timeout.inSeconds}s.',
          );
        },
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return ToolResult(
          toolId: id,
          output: '',
          success: false,
          error: 'DuckDuckGo returned HTTP ${response.statusCode}.',
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return const ToolResult(
          toolId: 'web_search',
          output: '',
          success: false,
          error: 'DuckDuckGo returned an unexpected payload.',
        );
      }

      final results = <_WebSearchEntry>[];
      final heading = (decoded['Heading'] as String?)?.trim();
      final abstract = (decoded['AbstractText'] as String?)?.trim();
      final abstractUrl = (decoded['AbstractURL'] as String?)?.trim();
      if ((heading ?? '').isNotEmpty || (abstract ?? '').isNotEmpty) {
        results.add(
          _WebSearchEntry(
            title: heading?.isNotEmpty == true ? heading! : query,
            url: abstractUrl?.isNotEmpty == true ? abstractUrl! : uri.toString(),
            snippet: abstract?.isNotEmpty == true ? abstract! : 'No abstract available.',
          ),
        );
      }
      _collectRelatedTopics(decoded['RelatedTopics'], results);

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

  void _collectRelatedTopics(
    dynamic value,
    List<_WebSearchEntry> results,
  ) {
    if (value is! List) return;
    for (final item in value) {
      if (item is Map<String, dynamic>) {
        final text = (item['Text'] as String?)?.trim();
        final url = (item['FirstURL'] as String?)?.trim();
        if ((text ?? '').isNotEmpty && (url ?? '').isNotEmpty) {
          results.add(
            _WebSearchEntry(
              title: text!.split(' - ').first,
              url: url!,
              snippet: text,
            ),
          );
        }
        _collectRelatedTopics(item['Topics'], results);
      }
    }
  }
}

class _WebSearchEntry {
  const _WebSearchEntry({
    required this.title,
    required this.url,
    required this.snippet,
  });

  final String title;
  final String url;
  final String snippet;
}

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'search_provider.dart';

class DuckDuckGoProvider implements SearchProvider {
  DuckDuckGoProvider({
    http.Client? client,
    this.timeout = const Duration(seconds: 5),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  @override
  Future<List<SearchResult>> search(
    String query, {
    int limit = 5,
  }) async {
    final normalizedLimit = limit.clamp(1, maxSearchResultsLimit);
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
      throw http.ClientException(
        'DuckDuckGo returned HTTP ${response.statusCode}.',
        uri,
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('DuckDuckGo returned an unexpected payload.');
    }

    final results = <SearchResult>[];
    final heading = (decoded['Heading'] as String?)?.trim();
    final abstract = (decoded['AbstractText'] as String?)?.trim();
    final abstractUrl = (decoded['AbstractURL'] as String?)?.trim();
    if ((heading ?? '').isNotEmpty || (abstract ?? '').isNotEmpty) {
      results.add(
        SearchResult(
          title: heading?.isNotEmpty ?? false ? heading! : query,
          url: abstractUrl?.isNotEmpty ?? false ? abstractUrl! : uri.toString(),
          snippet: abstract?.isNotEmpty ?? false
              ? abstract!
              : 'No abstract available.',
        ),
      );
    }

    _collectRelatedTopics(decoded['RelatedTopics'], results);
    return results.take(normalizedLimit).toList(growable: false);
  }

  void _collectRelatedTopics(
    dynamic value,
    List<SearchResult> results,
  ) {
    if (value is! List) return;
    for (final item in value) {
      if (item is Map<String, dynamic>) {
        final text = (item['Text'] as String?)?.trim();
        final url = (item['FirstURL'] as String?)?.trim();
        if ((text ?? '').isNotEmpty && (url ?? '').isNotEmpty) {
          results.add(
            SearchResult(
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

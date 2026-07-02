import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'search_provider.dart';

class DuckDuckGoProvider implements SearchProvider {
  DuckDuckGoProvider({
    http.Client? client,
    this.timeout = const Duration(seconds: 5),
  }) : _client = client ?? http.Client();

  final http.Client _client;

  @override
  final Duration timeout;

  @override
  Future<List<SearchResult>> search(
    String query, {
    int limit = 5,
  }) async {
    final clampedLimit = limit.clamp(1, searchResultsLimit);

    final uri = Uri.https(
      'api.duckduckgo.com',
      '/',
      {
        'q': query,
        'format': 'json',
        'no_html': '1',
        'skip_disambig': '1',
        'no_redirect': '1',
      },
    );

    debugPrint('[DDG] ============================================');
    debugPrint('[DDG] Starting search');
    debugPrint('[DDG] Query: $query');
    debugPrint('[DDG] URL: $uri');
    debugPrint('[DDG] Timeout: ${timeout.inSeconds}s');

    final stopwatch = Stopwatch()..start();

    try {
      final response = await _client
          .get(uri)
          .timeout(
            timeout,
            onTimeout: () {
              throw TimeoutException(
                'DuckDuckGo request timed out after ${timeout.inSeconds}s.',
              );
            },
          );

      stopwatch.stop();

      debugPrint('[DDG] HTTP ${response.statusCode}');
      debugPrint('[DDG] Elapsed ${stopwatch.elapsedMilliseconds} ms');

      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('[DDG] HTTP ERROR');
        debugPrint(response.body);

        throw http.ClientException(
          'DuckDuckGo returned HTTP ${response.statusCode}.',
          uri,
        );
      }

      debugPrint(
        '[DDG] Raw body (${response.body.length} chars)',
      );

      final decoded = jsonDecode(response.body);

      if (decoded is! Map<String, dynamic>) {
        throw const FormatException(
          'DuckDuckGo returned unexpected payload.',
        );
      }

      final heading =
          (decoded['Heading'] as String?)?.trim();

      final abstract =
          (decoded['AbstractText'] as String?)?.trim();

      final abstractUrl =
          (decoded['AbstractURL'] as String?)?.trim();

      debugPrint('[DDG] Heading: "$heading"');
      debugPrint('[DDG] Abstract length: ${abstract?.length ?? 0}');
      debugPrint('[DDG] AbstractURL: $abstractUrl');

      final results = <SearchResult>[];

      if ((heading ?? '').isNotEmpty ||
          (abstract ?? '').isNotEmpty) {
        results.add(
          SearchResult(
            title:
                heading?.isNotEmpty == true ? heading! : query,
            url: abstractUrl?.isNotEmpty == true
                ? abstractUrl!
                : uri.toString(),
            snippet: abstract?.isNotEmpty == true
                ? abstract!
                : 'No abstract available.',
          ),
        );
      }

      _collectRelatedTopics(
        decoded['RelatedTopics'],
        results,
      );

      debugPrint(
        '[DDG] Related topics collected: ${results.length}',
      );

      final output =
          results.take(clampedLimit).toList(growable: false);

      debugPrint('[DDG] Returning ${output.length} results');
      debugPrint('[DDG] ============================================');

      return output;
    } catch (e, s) {
      stopwatch.stop();

      debugPrint('[DDG] EXCEPTION');
      debugPrint(e.toString());
      debugPrint(s.toString());
      debugPrint('[DDG] ============================================');

      rethrow;
    }
  }

  void _collectRelatedTopics(
    dynamic value,
    List<SearchResult> results,
  ) {
    if (value is! List) return;

    for (final item in value) {
      if (item is Map<String, dynamic>) {
        final text =
            (item['Text'] as String?)?.trim();

        final url =
            (item['FirstURL'] as String?)?.trim();

        if ((text ?? '').isNotEmpty &&
            (url ?? '').isNotEmpty) {
          results.add(
            SearchResult(
              title: text!.split(' - ').first,
              url: url!,
              snippet: text,
            ),
          );
        }

        _collectRelatedTopics(
          item['Topics'],
          results,
        );
      }
    }
  }
}

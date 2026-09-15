import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';

import 'package:ai_orchestrator/core/tools/search/search_provider.dart';

class DuckDuckGoProvider implements SearchProvider {
  DuckDuckGoProvider({
    http.Client? client,
    this.timeout = const Duration(seconds: 5),
    this.enableDetailedDebugLogging = true,
    this.includeErrorDetailsInDiagnostics = true,
  }) : _client = client ?? http.Client();

  final http.Client _client;

  @override
  final Duration timeout;

  /// Keeps the historical verbose diagnostic output enabled by default so
  /// existing global/Workshop callers are behavior-compatible. Assistant can
  /// disable it because user search queries and returned payloads may contain
  /// private text that should not be copied into debug logs.
  final bool enableDetailedDebugLogging;

  /// Controls whether exception text is copied into RuntimeEventLog. Some HTTP
  /// exceptions include the request URI, which may contain the user's query.
  final bool includeErrorDetailsInDiagnostics;

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

    _debug('[DDG] ============================================');
    _debug('[DDG] Starting search');
    _debug('[DDG] Query: $query');
    _debug('[DDG] URL: $uri');
    _debug('[DDG] Timeout: ${timeout.inSeconds}s');
    RuntimeEventLog.instance.emit(
      '[WEBSEARCH_PROVIDER_SELECTED] provider=duckduckgo limit=$clampedLimit',
    );
    RuntimeEventLog.instance.emit(
      '[WEBSEARCH_HTTP_BEGIN] host=${uri.host} path=${uri.path}',
    );

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

      _debug('[DDG] HTTP ${response.statusCode}');
      RuntimeEventLog.instance.emit(
        response.statusCode >= 200 && response.statusCode < 300
            ? '[WEBSEARCH_HTTP_SUCCESS] status=${response.statusCode} elapsed_ms=${stopwatch.elapsedMilliseconds}'
            : '[WEBSEARCH_HTTP_FAILURE] status=${response.statusCode} elapsed_ms=${stopwatch.elapsedMilliseconds}',
      );
      _debug('[DDG] Elapsed ${stopwatch.elapsedMilliseconds} ms');

      if (response.statusCode < 200 || response.statusCode >= 300) {
        _debug('[DDG] HTTP ERROR');
        _debug(response.body);

        throw http.ClientException(
          'DuckDuckGo returned HTTP ${response.statusCode}.',
          uri,
        );
      }

      _debug(
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

      _debug('[DDG] Heading: "$heading"');
      _debug('[DDG] Abstract length: ${abstract?.length ?? 0}');
      _debug('[DDG] AbstractURL: $abstractUrl');

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

      _debug(
        '[DDG] Related topics collected: ${results.length}',
      );

      final output =
          results.take(clampedLimit).toList(growable: false);

      _debug('[DDG] Returning ${output.length} results');
      _debug('[DDG] ============================================');

      return output;
    } catch (e, s) {
      if (stopwatch.isRunning) stopwatch.stop();

      _debug('[DDG] EXCEPTION');
      _debug(e.toString());
      _debug(s.toString());
      RuntimeEventLog.instance.emit(
        e is TimeoutException
            ? includeErrorDetailsInDiagnostics
                ? '[WEBSEARCH_HTTP_TIMEOUT] elapsed_ms=${stopwatch.elapsedMilliseconds} error=$e'
                : '[WEBSEARCH_HTTP_TIMEOUT] elapsed_ms=${stopwatch.elapsedMilliseconds} error_type=${e.runtimeType}'
            : includeErrorDetailsInDiagnostics
                ? '[WEBSEARCH_HTTP_FAILURE] elapsed_ms=${stopwatch.elapsedMilliseconds} error=$e'
                : '[WEBSEARCH_HTTP_FAILURE] elapsed_ms=${stopwatch.elapsedMilliseconds} error_type=${e.runtimeType}',
      );
      _debug('[DDG] ============================================');

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

  void _debug(String message) {
    if (enableDetailedDebugLogging) {
      debugPrint(message);
    }
  }
}

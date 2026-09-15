import 'dart:async';

import 'package:http/http.dart' as http;

import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/tools/search/search_provider.dart';

/// Keyless general Web search backed by DuckDuckGo's non-JavaScript Lite
/// results page.
///
/// Unlike the Instant Answer endpoint, Lite exposes ordinary ranked Web links.
/// Parsing is deliberately small and defensive: if DuckDuckGo changes markup,
/// returns a challenge, or the request fails, callers can fall back to another
/// [SearchProvider] without making Internet a hard dependency.
final class DuckDuckGoLiteProvider implements SearchProvider {
  DuckDuckGoLiteProvider({
    http.Client? client,
    this.timeout = const Duration(seconds: 6),
    this.includeErrorDetailsInDiagnostics = true,
  }) : _client = client ?? http.Client();

  final http.Client _client;

  @override
  final Duration timeout;

  /// When false, exception text is not copied into RuntimeEventLog because an
  /// HTTP exception can contain the query-bearing request URI.
  final bool includeErrorDetailsInDiagnostics;

  @override
  Future<List<SearchResult>> search(
    String query, {
    int limit = 5,
  }) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) return const <SearchResult>[];

    final clampedLimit = limit.clamp(1, searchResultsLimit);
    final uri = Uri.https(
      'lite.duckduckgo.com',
      '/lite/',
      <String, String>{'q': normalizedQuery},
    );

    RuntimeEventLog.instance.emit(
      '[WEBSEARCH_PROVIDER_SELECTED] provider=duckduckgo_lite '
      'limit=$clampedLimit',
    );
    RuntimeEventLog.instance.emit(
      '[WEBSEARCH_HTTP_BEGIN] host=${uri.host} path=${uri.path}',
    );

    final stopwatch = Stopwatch()..start();
    try {
      final response = await _client
          .get(
            uri,
            headers: const <String, String>{
              'Accept': 'text/html,application/xhtml+xml',
              'User-Agent':
                  'Mozilla/5.0 (compatible; AI-Orchestrator/1.0; +https://github.com/pilialvu75-hue/Ai-orchestrator-riserva)',
            },
          )
          .timeout(
            timeout,
            onTimeout: () => throw TimeoutException(
              'DuckDuckGo Lite timed out after ${timeout.inSeconds}s.',
            ),
          );

      stopwatch.stop();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        RuntimeEventLog.instance.emit(
          '[WEBSEARCH_HTTP_FAILURE] provider=duckduckgo_lite '
          'status=${response.statusCode} '
          'elapsed_ms=${stopwatch.elapsedMilliseconds}',
        );
        throw http.ClientException(
          'DuckDuckGo Lite returned HTTP ${response.statusCode}.',
          uri,
        );
      }

      final body = response.body;
      if (_looksBlocked(body)) {
        RuntimeEventLog.instance.emit(
          '[WEBSEARCH_HTTP_FAILURE] provider=duckduckgo_lite '
          'reason=challenge elapsed_ms=${stopwatch.elapsedMilliseconds}',
        );
        throw const FormatException(
          'DuckDuckGo Lite returned a challenge page.',
        );
      }

      final results = _parseResults(body, limit: clampedLimit);
      RuntimeEventLog.instance.emit(
        '[WEBSEARCH_HTTP_SUCCESS] provider=duckduckgo_lite '
        'status=${response.statusCode} '
        'elapsed_ms=${stopwatch.elapsedMilliseconds} '
        'results=${results.length}',
      );
      return results;
    } catch (error) {
      if (stopwatch.isRunning) stopwatch.stop();
      RuntimeEventLog.instance.emit(
        error is TimeoutException
            ? '[WEBSEARCH_HTTP_TIMEOUT] provider=duckduckgo_lite '
                'elapsed_ms=${stopwatch.elapsedMilliseconds} '
                'error_type=${error.runtimeType}'
            : includeErrorDetailsInDiagnostics
                ? '[WEBSEARCH_HTTP_FAILURE] provider=duckduckgo_lite '
                    'elapsed_ms=${stopwatch.elapsedMilliseconds} '
                    'error=$error'
                : '[WEBSEARCH_HTTP_FAILURE] provider=duckduckgo_lite '
                    'elapsed_ms=${stopwatch.elapsedMilliseconds} '
                    'error_type=${error.runtimeType}',
      );
      rethrow;
    }
  }

  static List<SearchResult> _parseResults(
    String html, {
    required int limit,
  }) {
    final snippets = RegExp(
      r'''<td\b[^>]*class\s*=\s*["'][^"']*\bresult-snippet\b[^"']*["'][^>]*>([\s\S]*?)</td>''',
      caseSensitive: false,
    )
        .allMatches(html)
        .map((match) => _cleanHtml(match.group(1) ?? ''))
        .toList(growable: false);

    final results = <SearchResult>[];
    final anchorPattern = RegExp(
      r'''<a\b([^>]*)>([\s\S]*?)</a>''',
      caseSensitive: false,
    );

    for (final match in anchorPattern.allMatches(html)) {
      if (results.length >= limit) break;

      final attributes = match.group(1) ?? '';
      final className = _attribute(attributes, 'class');
      if (className == null ||
          !className.toLowerCase().split(RegExp(r'\s+')).contains('result-link')) {
        continue;
      }

      final rawHref = _attribute(attributes, 'href');
      final title = _cleanHtml(match.group(2) ?? '');
      final url = _destinationUrl(rawHref);
      if (title.isEmpty || url == null) continue;

      final snippetIndex = results.length;
      final snippet = snippetIndex < snippets.length
          ? snippets[snippetIndex]
          : title;

      results.add(
        SearchResult(
          title: title,
          url: url,
          snippet: snippet.isEmpty ? title : snippet,
        ),
      );
    }

    return List<SearchResult>.unmodifiable(results);
  }

  static String? _attribute(String attributes, String name) {
    final escapedName = RegExp.escape(name);
    final doubleQuoted = RegExp(
      '$escapedName\\s*=\\s*"([^"]*)"',
      caseSensitive: false,
    ).firstMatch(attributes);
    if (doubleQuoted != null) {
      return _decodeEntities(doubleQuoted.group(1) ?? '').trim();
    }

    final singleQuoted = RegExp(
      "$escapedName\\s*=\\s*'([^']*)'",
      caseSensitive: false,
    ).firstMatch(attributes);
    if (singleQuoted != null) {
      return _decodeEntities(singleQuoted.group(1) ?? '').trim();
    }

    return null;
  }

  static String? _destinationUrl(String? rawHref) {
    final href = rawHref?.trim();
    if (href == null || href.isEmpty) return null;

    Uri? uri = Uri.tryParse(href);
    if (uri == null) return null;

    if (!uri.hasScheme) {
      uri = Uri.parse('https://lite.duckduckgo.com').resolveUri(uri);
    }

    final redirectTarget = uri.queryParameters['uddg'];
    if (redirectTarget != null && redirectTarget.trim().isNotEmpty) {
      final target = Uri.tryParse(redirectTarget.trim());
      if (target != null && _isHttp(target)) {
        return target.toString();
      }
    }

    return _isHttp(uri) ? uri.toString() : null;
  }

  static bool _isHttp(Uri uri) =>
      uri.scheme.toLowerCase() == 'https' || uri.scheme.toLowerCase() == 'http';

  static bool _looksBlocked(String body) {
    final lower = body.toLowerCase();
    return lower.contains('captcha') ||
        lower.contains('unusual traffic') ||
        lower.contains('anomaly') ||
        lower.contains('challenge-form');
  }

  static String _cleanHtml(String value) {
    final withoutTags = value.replaceAll(RegExp(r'<[^>]+>'), ' ');
    return _decodeEntities(withoutTags)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String _decodeEntities(String value) {
    var output = value
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&#x27;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ');

    output = output.replaceAllMapped(
      RegExp(r'&#(x?[0-9a-fA-F]+);'),
      (match) {
        final token = match.group(1) ?? '';
        final isHex = token.startsWith('x') || token.startsWith('X');
        final digits = isHex ? token.substring(1) : token;
        final codePoint = int.tryParse(digits, radix: isHex ? 16 : 10);
        if (codePoint == null || codePoint < 0 || codePoint > 0x10FFFF) {
          return match.group(0) ?? '';
        }
        return String.fromCharCode(codePoint);
      },
    );

    return output;
  }
}

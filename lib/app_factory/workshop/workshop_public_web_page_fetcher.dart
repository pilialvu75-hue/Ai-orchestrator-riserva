import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';

typedef WorkshopHostResolver = Future<List<InternetAddress>> Function(
  String host,
);

enum WorkshopWebPageFetchStatus {
  fetched,
  skippedOffline,
  rejectedUrl,
  unsupportedContent,
  httpFailure,
  tooLarge,
  unavailable,
}

final class WorkshopFetchedWebPage {
  const WorkshopFetchedWebPage({
    required this.url,
    required this.contentType,
    required this.text,
    required this.bytesRead,
    required this.redirectCount,
  });

  final Uri url;
  final String contentType;
  final String text;
  final int bytesRead;
  final int redirectCount;
}

final class WorkshopWebPageFetchResult {
  const WorkshopWebPageFetchResult({
    required this.status,
    this.page,
    this.reason,
  });

  final WorkshopWebPageFetchStatus status;
  final WorkshopFetchedWebPage? page;
  final String? reason;

  bool get isSuccess =>
      status == WorkshopWebPageFetchStatus.fetched && page != null;
}

/// Read-only public Web page fetcher for Cantiere research.
///
/// This component deliberately does less than a browser. It only accepts
/// public HTTP(S) destinations, performs a DNS guard before every request,
/// follows a small number of redirects manually so every destination is
/// revalidated, accepts text-like content only, and caps downloaded bytes.
/// It never executes JavaScript, sends credentials, downloads binary assets or
/// mutates project state.
final class WorkshopPublicWebPageFetcher {
  WorkshopPublicWebPageFetcher({
    http.Client? client,
    WorkshopHostResolver? resolver,
    this.timeout = const Duration(seconds: 8),
    this.maxBytes = 256 * 1024,
    this.maxTextChars = 24000,
    this.maxRedirects = 3,
  })  : assert(maxBytes > 0),
        assert(maxTextChars > 0),
        assert(maxRedirects >= 0),
        _client = client ?? http.Client(),
        _resolver = resolver ?? _defaultResolver;

  final http.Client _client;
  final WorkshopHostResolver _resolver;
  final Duration timeout;
  final int maxBytes;
  final int maxTextChars;
  final int maxRedirects;

  Future<WorkshopWebPageFetchResult> fetch(
    String rawUrl, {
    bool isOffline = false,
  }) async {
    if (isOffline) {
      _log('status=skipped reason=offline');
      return const WorkshopWebPageFetchResult(
        status: WorkshopWebPageFetchStatus.skippedOffline,
        reason: 'offline',
      );
    }

    final initial = Uri.tryParse(rawUrl.trim());
    if (initial == null) {
      _log('status=rejected reason=invalid_uri');
      return const WorkshopWebPageFetchResult(
        status: WorkshopWebPageFetchStatus.rejectedUrl,
        reason: 'invalid_uri',
      );
    }

    var current = initial;
    final visited = <String>{};

    for (var redirectCount = 0;
        redirectCount <= maxRedirects;
        redirectCount++) {
      final rejection = await _publicUrlRejectionReason(current);
      if (rejection != null) {
        _log(
          'status=rejected reason=$rejection host=${_safeHost(current)} '
          'redirects=$redirectCount',
        );
        return WorkshopWebPageFetchResult(
          status: WorkshopWebPageFetchStatus.rejectedUrl,
          reason: rejection,
        );
      }

      final canonical = current.toString();
      if (!visited.add(canonical)) {
        _log(
          'status=rejected reason=redirect_loop host=${_safeHost(current)} '
          'redirects=$redirectCount',
        );
        return const WorkshopWebPageFetchResult(
          status: WorkshopWebPageFetchStatus.rejectedUrl,
          reason: 'redirect_loop',
        );
      }

      http.StreamedResponse response;
      try {
        final request = http.Request('GET', current)
          ..followRedirects = false
          ..maxRedirects = 0
          ..headers.addAll(const <String, String>{
            'Accept': 'text/html,application/xhtml+xml,text/plain;q=0.9',
            'User-Agent':
                'Mozilla/5.0 (compatible; AI-Orchestrator/1.0; +https://github.com/pilialvu75-hue/Ai-orchestrator-riserva)',
          });

        response = await _client.send(request).timeout(timeout);
      } catch (error) {
        _log(
          'status=unavailable host=${_safeHost(current)} '
          'error_type=${error.runtimeType}',
        );
        return const WorkshopWebPageFetchResult(
          status: WorkshopWebPageFetchStatus.unavailable,
          reason: 'request_failed',
        );
      }

      if (_isRedirect(response.statusCode)) {
        final location = response.headers['location'];
        await response.stream.drain();

        if (location == null || location.trim().isEmpty) {
          _log(
            'status=http_failure reason=redirect_without_location '
            'host=${_safeHost(current)} status_code=${response.statusCode}',
          );
          return const WorkshopWebPageFetchResult(
            status: WorkshopWebPageFetchStatus.httpFailure,
            reason: 'redirect_without_location',
          );
        }

        if (redirectCount >= maxRedirects) {
          _log(
            'status=rejected reason=too_many_redirects '
            'host=${_safeHost(current)} redirects=$redirectCount',
          );
          return const WorkshopWebPageFetchResult(
            status: WorkshopWebPageFetchStatus.rejectedUrl,
            reason: 'too_many_redirects',
          );
        }

        final next = Uri.tryParse(location.trim());
        if (next == null) {
          _log(
            'status=rejected reason=invalid_redirect '
            'host=${_safeHost(current)}',
          );
          return const WorkshopWebPageFetchResult(
            status: WorkshopWebPageFetchStatus.rejectedUrl,
            reason: 'invalid_redirect',
          );
        }

        current = current.resolveUri(next);
        continue;
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.drain();
        _log(
          'status=http_failure host=${_safeHost(current)} '
          'status_code=${response.statusCode}',
        );
        return WorkshopWebPageFetchResult(
          status: WorkshopWebPageFetchStatus.httpFailure,
          reason: 'http_${response.statusCode}',
        );
      }

      final contentType =
          (response.headers['content-type'] ?? '').trim().toLowerCase();
      if (!_isSupportedTextContentType(contentType)) {
        await response.stream.drain();
        _log(
          'status=unsupported_content host=${_safeHost(current)}',
        );
        return const WorkshopWebPageFetchResult(
          status: WorkshopWebPageFetchStatus.unsupportedContent,
          reason: 'unsupported_content_type',
        );
      }

      final declaredLength =
          int.tryParse(response.headers['content-length'] ?? '');
      if (declaredLength != null && declaredLength > maxBytes) {
        await response.stream.drain();
        _log(
          'status=too_large host=${_safeHost(current)} '
          'declared_bytes=$declaredLength max_bytes=$maxBytes',
        );
        return const WorkshopWebPageFetchResult(
          status: WorkshopWebPageFetchStatus.tooLarge,
          reason: 'declared_size_limit',
        );
      }

      final bytes = <int>[];
      try {
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > maxBytes) {
            _log(
              'status=too_large host=${_safeHost(current)} '
              'max_bytes=$maxBytes',
            );
            return const WorkshopWebPageFetchResult(
              status: WorkshopWebPageFetchStatus.tooLarge,
              reason: 'stream_size_limit',
            );
          }
          bytes.addAll(chunk);
        }
      } catch (error) {
        _log(
          'status=unavailable host=${_safeHost(current)} '
          'error_type=${error.runtimeType}',
        );
        return const WorkshopWebPageFetchResult(
          status: WorkshopWebPageFetchStatus.unavailable,
          reason: 'response_stream_failed',
        );
      }

      final decoded = utf8.decode(bytes, allowMalformed: true);
      final text = _isHtml(contentType)
          ? _cleanHtmlDocument(decoded)
          : _cleanPlainText(decoded);
      if (text.isEmpty) {
        _log(
          'status=unavailable reason=empty_text host=${_safeHost(current)}',
        );
        return const WorkshopWebPageFetchResult(
          status: WorkshopWebPageFetchStatus.unavailable,
          reason: 'empty_text',
        );
      }

      final boundedText = text.length <= maxTextChars
          ? text
          : '${text.substring(0, maxTextChars).trimRight()}\n[truncated]';

      _log(
        'status=fetched host=${_safeHost(current)} bytes=${bytes.length} '
        'chars=${boundedText.length} redirects=$redirectCount',
      );
      return WorkshopWebPageFetchResult(
        status: WorkshopWebPageFetchStatus.fetched,
        page: WorkshopFetchedWebPage(
          url: current,
          contentType: contentType,
          text: boundedText,
          bytesRead: bytes.length,
          redirectCount: redirectCount,
        ),
      );
    }

    return const WorkshopWebPageFetchResult(
      status: WorkshopWebPageFetchStatus.rejectedUrl,
      reason: 'too_many_redirects',
    );
  }

  Future<String?> _publicUrlRejectionReason(Uri uri) async {
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return 'unsupported_scheme';
    if (!uri.hasAuthority || uri.host.trim().isEmpty) return 'missing_host';
    if (uri.userInfo.isNotEmpty) return 'userinfo_not_allowed';

    if (uri.hasPort) {
      final expected = scheme == 'https' ? 443 : 80;
      if (uri.port != expected) return 'non_default_port';
    }

    final host = uri.host.trim().toLowerCase();
    if (host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        host.endsWith('.home.arpa')) {
      return 'local_host';
    }

    final literal = InternetAddress.tryParse(host);
    if (literal != null) {
      return _isPublicAddress(literal) ? null : 'non_public_ip';
    }

    List<InternetAddress> addresses;
    try {
      addresses = await _resolver(host).timeout(timeout);
    } catch (_) {
      return 'dns_unavailable';
    }

    if (addresses.isEmpty) return 'dns_unavailable';
    if (addresses.any((address) => !_isPublicAddress(address))) {
      return 'non_public_dns_result';
    }

    return null;
  }

  static Future<List<InternetAddress>> _defaultResolver(String host) {
    return InternetAddress.lookup(host, type: InternetAddressType.any);
  }

  static bool _isPublicAddress(InternetAddress address) {
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4 && bytes.length == 4) {
      return _isPublicIpv4(bytes);
    }

    if (address.type == InternetAddressType.IPv6 && bytes.length == 16) {
      if (bytes.every((value) => value == 0)) return false;
      if (bytes.take(15).every((value) => value == 0) && bytes[15] == 1) {
        return false;
      }
      if ((bytes[0] & 0xfe) == 0xfc) return false; // fc00::/7 ULA
      if (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) {
        return false; // fe80::/10 link-local
      }
      if (bytes[0] == 0xff) return false; // multicast
      if (bytes[0] == 0x20 &&
          bytes[1] == 0x01 &&
          bytes[2] == 0x0d &&
          bytes[3] == 0xb8) {
        return false; // 2001:db8::/32 documentation
      }

      final isIpv4Mapped =
          bytes.take(10).every((value) => value == 0) &&
              bytes[10] == 0xff &&
              bytes[11] == 0xff;
      if (isIpv4Mapped) {
        return _isPublicIpv4(bytes.sublist(12));
      }

      return true;
    }

    return false;
  }

  static bool _isPublicIpv4(List<int> bytes) {
    final a = bytes[0];
    final b = bytes[1];
    final c = bytes[2];

    if (a == 0 || a == 10 || a == 127 || a >= 224) return false;
    if (a == 100 && b >= 64 && b <= 127) return false; // CGNAT
    if (a == 169 && b == 254) return false; // link-local
    if (a == 172 && b >= 16 && b <= 31) return false;
    if (a == 192 && b == 168) return false;
    if (a == 192 && b == 0 && c == 0) return false;
    if (a == 192 && b == 0 && c == 2) return false; // TEST-NET-1
    if (a == 198 && (b == 18 || b == 19)) return false; // benchmark
    if (a == 198 && b == 51 && c == 100) return false; // TEST-NET-2
    if (a == 203 && b == 0 && c == 113) return false; // TEST-NET-3

    return true;
  }

  static bool _isRedirect(int statusCode) =>
      statusCode == 301 ||
      statusCode == 302 ||
      statusCode == 303 ||
      statusCode == 307 ||
      statusCode == 308;

  static bool _isSupportedTextContentType(String value) {
    if (value.isEmpty) return false;
    final mime = value.split(';').first.trim();
    return mime.startsWith('text/') || mime == 'application/xhtml+xml';
  }

  static bool _isHtml(String contentType) {
    final mime = contentType.split(';').first.trim();
    return mime == 'text/html' || mime == 'application/xhtml+xml';
  }

  String _cleanHtmlDocument(String value) {
    var output = value
        .replaceAll(
          RegExp(r'<script\b[^>]*>[\s\S]*?</script>', caseSensitive: false),
          ' ',
        )
        .replaceAll(
          RegExp(r'<style\b[^>]*>[\s\S]*?</style>', caseSensitive: false),
          ' ',
        )
        .replaceAll(
          RegExp(r'<noscript\b[^>]*>[\s\S]*?</noscript>', caseSensitive: false),
          ' ',
        )
        .replaceAll(RegExp(r'<!--[\s\S]*?-->'), ' ')
        .replaceAll(
          RegExp(
            r'</?(?:p|div|br|li|h[1-6]|tr|td|th|article|section|main|header|footer)\b[^>]*>',
            caseSensitive: false,
          ),
          '\n',
        )
        .replaceAll(RegExp(r'<[^>]+>'), ' ');

    output = _decodeEntities(output);
    return _cleanPlainText(output);
  }

  static String _cleanPlainText(String value) {
    return value
        .replaceAll(RegExp(r'[\t ]+'), ' ')
        .replaceAll(RegExp(r' *\n *'), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
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

  static String _safeHost(Uri uri) {
    final host = uri.host.trim().toLowerCase();
    return host.isEmpty ? 'none' : host;
  }

  static void _log(String details) {
    RuntimeEventLog.instance.emit('[WORKSHOP_WEB_PAGE_FETCH] $details');
  }
}

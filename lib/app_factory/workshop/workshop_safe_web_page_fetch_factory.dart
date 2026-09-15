import 'dart:io';

import 'package:ai_orchestrator/app_factory/workshop/workshop_pinned_public_http_client.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_public_web_page_fetcher.dart';

/// Production composition boundary for Cantiere page retrieval.
///
/// Callers should obtain the page fetcher here instead of constructing a raw
/// HTTP client themselves. The same resolver is used by the fetcher's early
/// URL/DNS guard and by the socket-level pinned transport; the latter performs
/// the authoritative validation again at connection time and opens the socket
/// directly to the validated numeric address.
abstract final class WorkshopSafeWebPageFetchFactory {
  static WorkshopPublicWebPageFetcher create({
    WorkshopHostResolver? resolver,
    Duration timeout = const Duration(seconds: 8),
    int maxBytes = 256 * 1024,
    int maxTextChars = 24000,
    int maxRedirects = 3,
  }) {
    final resolved = resolver ?? _defaultResolver;
    return WorkshopPublicWebPageFetcher(
      client: WorkshopPinnedPublicHttpClient(
        resolver: resolved,
        connectionTimeout: timeout,
      ),
      resolver: resolved,
      timeout: timeout,
      maxBytes: maxBytes,
      maxTextChars: maxTextChars,
      maxRedirects: maxRedirects,
    );
  }

  static Future<List<InternetAddress>> _defaultResolver(String host) {
    return InternetAddress.lookup(host, type: InternetAddressType.any);
  }
}

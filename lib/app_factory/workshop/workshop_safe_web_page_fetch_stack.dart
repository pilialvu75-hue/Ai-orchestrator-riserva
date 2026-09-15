import 'dart:io';

import 'package:ai_orchestrator/app_factory/workshop/workshop_pinned_dns_resolver.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_pinned_public_http_client.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_public_web_page_fetcher.dart';

/// Owns the hardened transport used when Cantiere opens one selected public
/// research source.
///
/// Production should construct page fetching through this stack rather than a
/// bare [WorkshopPublicWebPageFetcher]. The URL guard and TCP transport share
/// one short-lived DNS snapshot, closing the validate-public / connect-private
/// rebinding gap while preserving normal HTTPS certificate verification for the
/// original hostname.
final class WorkshopSafeWebPageFetchStack {
  WorkshopSafeWebPageFetchStack._({
    required this.fetcher,
    required WorkshopPinnedPublicHttpClient client,
    required this.dnsResolver,
  }) : _client = client;

  factory WorkshopSafeWebPageFetchStack.create({
    WorkshopDnsLookup? lookup,
    Duration dnsPinTtl = const Duration(seconds: 30),
    Duration timeout = const Duration(seconds: 8),
    int maxBytes = 256 * 1024,
    int maxTextChars = 24000,
    int maxRedirects = 3,
  }) {
    final dnsResolver = WorkshopPinnedDnsResolver(
      lookup: lookup,
      ttl: dnsPinTtl,
    );
    final client = WorkshopPinnedPublicHttpClient(
      resolver: dnsResolver.resolve,
      connectionTimeout: timeout,
    );
    final fetcher = WorkshopPublicWebPageFetcher(
      client: client,
      resolver: dnsResolver.resolve,
      timeout: timeout,
      maxBytes: maxBytes,
      maxTextChars: maxTextChars,
      maxRedirects: maxRedirects,
    );

    return WorkshopSafeWebPageFetchStack._(
      fetcher: fetcher,
      client: client,
      dnsResolver: dnsResolver,
    );
  }

  final WorkshopPublicWebPageFetcher fetcher;
  final WorkshopPinnedDnsResolver dnsResolver;
  final WorkshopPinnedPublicHttpClient _client;

  void close() {
    _client.close();
    dnsResolver.clear();
  }
}

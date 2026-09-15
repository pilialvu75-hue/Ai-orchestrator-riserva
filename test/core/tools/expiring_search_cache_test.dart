import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/core/tools/search/expiring_search_cache.dart';
import 'package:ai_orchestrator/core/tools/search/search_provider.dart';

void main() {
  const result = SearchResult(
    title: 'Fresh result',
    url: 'https://example.test/fresh',
    snippet: 'Fresh snippet',
  );

  test('returns cached results before TTL expires', () {
    var now = DateTime(2026, 9, 15, 12);
    final cache = ExpiringSearchCache(
      ttl: const Duration(minutes: 3),
      now: () => now,
    );

    cache.put('Weather Paris', const <SearchResult>[result]);
    now = now.add(const Duration(minutes: 2));

    expect(cache.get(' weather PARIS '), const <SearchResult>[result]);
  });

  test('drops cached results when TTL expires', () {
    var now = DateTime(2026, 9, 15, 12);
    final cache = ExpiringSearchCache(
      ttl: const Duration(minutes: 3),
      now: () => now,
    );

    cache.put('latest news', const <SearchResult>[result]);
    now = now.add(const Duration(minutes: 3));

    expect(cache.get('latest news'), isNull);
  });

  test('evicts least recently used entry when capacity is exceeded', () {
    var now = DateTime(2026, 9, 15, 12);
    final cache = ExpiringSearchCache(
      ttl: const Duration(minutes: 10),
      maxEntries: 2,
      now: () => now,
    );

    cache.put('one', const <SearchResult>[result]);
    now = now.add(const Duration(seconds: 1));
    cache.put('two', const <SearchResult>[result]);

    // Refresh entry one so entry two becomes the least recently used.
    expect(cache.get('one'), isNotNull);
    now = now.add(const Duration(seconds: 1));
    cache.put('three', const <SearchResult>[result]);

    expect(cache.get('one'), isNotNull);
    expect(cache.get('two'), isNull);
    expect(cache.get('three'), isNotNull);
  });
}

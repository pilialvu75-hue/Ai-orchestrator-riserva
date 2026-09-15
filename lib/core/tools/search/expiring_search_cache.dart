import 'dart:collection';

import 'package:ai_orchestrator/core/tools/search/search_cache.dart';
import 'package:ai_orchestrator/core/tools/search/search_provider.dart';

/// Small in-memory cache for fresh Assistant Web results.
///
/// Time-sensitive Assistant queries must not live for the entire app process:
/// weather, news, prices and scores can become stale quickly. This cache keeps
/// only a bounded number of entries and expires them after [ttl].
final class ExpiringSearchCache implements SearchCache {
  ExpiringSearchCache({
    this.ttl = const Duration(minutes: 3),
    this.maxEntries = 64,
    DateTime Function()? now,
  })  : assert(!ttl.isNegative),
        assert(maxEntries > 0),
        _now = now ?? DateTime.now;

  final Duration ttl;
  final int maxEntries;
  final DateTime Function() _now;
  final LinkedHashMap<String, _ExpiringSearchCacheEntry> _entries =
      LinkedHashMap<String, _ExpiringSearchCacheEntry>();

  String _normalize(String query) => query.trim().toLowerCase();

  @override
  List<SearchResult>? get(String query) {
    final key = _normalize(query);
    final entry = _entries.remove(key);
    if (entry == null) return null;

    final age = _now().difference(entry.createdAt);
    if (age >= ttl) {
      return null;
    }

    // Reinsert a hit so the map also acts as a tiny LRU cache.
    _entries[key] = entry;
    return List<SearchResult>.unmodifiable(entry.results);
  }

  @override
  void put(String query, List<SearchResult> results) {
    final key = _normalize(query);
    if (key.isEmpty) return;

    _entries.remove(key);
    _entries[key] = _ExpiringSearchCacheEntry(
      createdAt: _now(),
      results: List<SearchResult>.unmodifiable(results),
    );

    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  @override
  void clear() => _entries.clear();
}

final class _ExpiringSearchCacheEntry {
  const _ExpiringSearchCacheEntry({
    required this.createdAt,
    required this.results,
  });

  final DateTime createdAt;
  final List<SearchResult> results;
}

import 'search_provider.dart';

abstract class SearchCache {
  List<SearchResult>? get(String query);

  void put(String query, List<SearchResult> results);

  void clear();
}

class InMemorySearchCache implements SearchCache {
  final Map<String, List<SearchResult>> _cache = <String, List<SearchResult>>{};

  String _normalize(String query) => query.trim().toLowerCase();

  @override
  List<SearchResult>? get(String query) {
    final cached = _cache[_normalize(query)];
    if (cached == null) {
      return null;
    }
    return List<SearchResult>.unmodifiable(cached);
  }

  @override
  void put(String query, List<SearchResult> results) {
    _cache[_normalize(query)] = List<SearchResult>.unmodifiable(results);
  }

  @override
  void clear() {
    _cache.clear();
  }
}

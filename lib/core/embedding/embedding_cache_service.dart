class EmbeddingCacheService {
  EmbeddingCacheService({int maxSize = 1024}) : _maxSize = maxSize;

  final int _maxSize;
  final Map<String, List<double>> _cache = {};

  List<double>? get(String text) => _cache[text];

  void put(String text, List<double> embedding) {
    if (_cache.length >= _maxSize && !_cache.containsKey(text)) {
      // Evict the oldest entry (insertion-order in LinkedHashMap).
      _cache.remove(_cache.keys.first);
    }
    _cache[text] = embedding;
  }

  void evict(String text) {
    _cache.remove(text);
  }

  void clear() {
    _cache.clear();
  }

  int get size => _cache.length;
}

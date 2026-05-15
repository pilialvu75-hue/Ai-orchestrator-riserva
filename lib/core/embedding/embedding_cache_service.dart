class EmbeddingCacheService {
  final Map<String, List<double>> _cache = {};

  List<double>? get(String text) => _cache[text];

  void put(String text, List<double> embedding) {
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

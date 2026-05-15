import 'package:flutter/foundation.dart';

import 'package:ai_orchestrator/core/embedding/embedding_cache_service.dart';
import 'package:ai_orchestrator/core/embedding/embedding_runtime.dart';
import 'package:ai_orchestrator/core/embedding/semantic_search_service.dart';
import 'package:ai_orchestrator/core/embedding/vector_store_service.dart';

class EmbeddingService {
  EmbeddingService({
    EmbeddingRuntime? runtime,
    EmbeddingCacheService? cache,
    VectorStoreService? store,
  })  : _runtime = runtime ?? MockEmbeddingRuntime(),
        _cache = cache ?? EmbeddingCacheService(),
        _store = store ?? VectorStoreService() {
    _search = SemanticSearchService(runtime: _runtime, store: _store);
  }

  final EmbeddingRuntime _runtime;
  final EmbeddingCacheService _cache;
  final VectorStoreService _store;
  late final SemanticSearchService _search;

  Future<bool> initialize() async {
    final result = await _runtime.initialize();
    if (result) {
      debugPrint(
        '[EMBEDDING_READY] OK – embedding service initialized '
        '(provider: ${_runtime.providerName})',
      );
    } else {
      debugPrint('[EMBEDDING_READY] FAIL – embedding service failed to initialize');
    }
    return result;
  }

  Future<List<double>> embed(String text) async {
    final cached = _cache.get(text);
    if (cached != null) return cached;

    final embedding = await _runtime.generateEmbedding(text);
    _cache.put(text, embedding);
    return embedding;
  }

  Future<List<SemanticSearchResult>> search(
    String query, {
    int topK = 5,
  }) =>
      _search.search(query, topK: topK);

  Future<void> indexText(String id, String text) async {
    final embedding = await embed(text);
    _store.add(VectorEntry(id: id, text: text, embedding: embedding));
  }

  bool get isReady => _runtime.isReady;

  void dispose() {
    _runtime.dispose();
    _cache.clear();
  }
}

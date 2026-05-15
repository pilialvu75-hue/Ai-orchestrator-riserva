import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:ai_orchestrator/core/embedding/embedding_runtime.dart';
import 'package:ai_orchestrator/core/embedding/vector_store_service.dart';

@immutable
class SemanticSearchResult {
  const SemanticSearchResult({required this.entry, required this.score});

  final VectorEntry entry;
  final double score;
}

class SemanticSearchService {
  SemanticSearchService({
    required EmbeddingRuntime runtime,
    required VectorStoreService store,
  })  : _runtime = runtime,
        _store = store;

  final EmbeddingRuntime _runtime;
  final VectorStoreService _store;

  Future<List<SemanticSearchResult>> search(
    String query, {
    int topK = 5,
  }) async {
    final queryEmbedding = await _runtime.generateEmbedding(query);
    final entries = _store.getAll();

    if (entries.isEmpty) return [];

    final results = entries
        .map((entry) => SemanticSearchResult(
              entry: entry,
              score: _cosineSimilarity(queryEmbedding, entry.embedding),
            ))
        .toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    return results.take(topK).toList();
  }

  double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.isEmpty || b.isEmpty || a.length != b.length) return 0.0;

    double dot = 0.0;
    double normA = 0.0;
    double normB = 0.0;

    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }

    final denom = math.sqrt(normA) * math.sqrt(normB);
    if (denom == 0.0) return 0.0;

    return dot / denom;
  }
}

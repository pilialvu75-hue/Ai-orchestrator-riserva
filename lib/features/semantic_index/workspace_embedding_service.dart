import 'dart:math' as math;

class WorkspaceEmbeddingService {
  const WorkspaceEmbeddingService({
    this.embeddingSize = 96,
  });

  final int embeddingSize;

  List<double> embedText(String text) {
    final vector = List<double>.filled(embeddingSize, 0);
    final tokens = text
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9_]+'))
        .where((token) => token.isNotEmpty);
    for (final token in tokens) {
      final idx = token.hashCode.abs() % embeddingSize;
      vector[idx] += 1;
    }
    return _normalize(vector);
  }

  double cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length || a.isEmpty) return 0;
    var dot = 0.0;
    var normA = 0.0;
    var normB = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    if (normA == 0 || normB == 0) return 0;
    return dot / (math.sqrt(normA) * math.sqrt(normB));
  }

  List<double> _normalize(List<double> vector) {
    var norm = 0.0;
    for (final value in vector) {
      norm += value * value;
    }
    if (norm == 0) return vector;
    final denom = math.sqrt(norm);
    return vector.map((value) => value / denom).toList(growable: false);
  }
}


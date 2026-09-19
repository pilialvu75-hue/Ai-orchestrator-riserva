import 'dart:math' as math;
import 'package:flutter/foundation.dart';

class WorkspaceEmbeddingService {
  const WorkspaceEmbeddingService({
    this.embeddingSize = 192,
  });

  final int embeddingSize;

  Future<List<double>> embedTextAsync(String text) async {
    final stopwatch = Stopwatch()..start();
    final vector = embedText(text);
    stopwatch.stop();
    debugPrint(
      '[EMBEDDING_GENERATE] mode=local_semantic chars=${text.length} dims=$embeddingSize elapsed_ms=${stopwatch.elapsedMilliseconds}',
    );
    return vector;
  }

  List<double> embedText(String text) {
    final vector = List<double>.filled(embeddingSize, 0);
    final normalized = text
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalized.isEmpty) {
      return vector;
    }
    final legacyTokens = normalized
        .split(RegExp(r'[^a-z0-9_]+'))
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
    final unicodeTokens = normalized
        .split(RegExp(r'[^\p{L}\p{N}_]+', unicode: true))
        .where((token) => token.isNotEmpty)
        .toList(growable: false);

    if (legacyTokens.isEmpty && unicodeTokens.isEmpty) return vector;

    // Keep the historical ASCII feature path exactly unchanged so vectors
    // already persisted on device remain comparable after this upgrade.
    _accumulateTokenFeatures(vector, legacyTokens);

    // Unicode-only additions improve accented/non-Latin text while retaining
    // the legacy feature signal above for backward compatibility.
    if (!_sameTokens(legacyTokens, unicodeTokens)) {
      _accumulateTokenFeatures(
        vector,
        unicodeTokens,
        scale: 0.65,
      );
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

  void _accumulateTokenFeatures(
    List<double> vector,
    List<String> tokens, {
    double scale = 1.0,
  }) {
    if (tokens.isEmpty || scale <= 0) return;

    for (var i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      final positionWeight = 1.0 + (i / math.max(1, tokens.length));
      _accumulateFeature(vector, token, 1.0 * positionWeight * scale);
      for (final ngram in _characterNGrams(token, 3)) {
        _accumulateFeature(vector, ngram, 0.6 * positionWeight * scale);
      }
      for (final ngram in _characterNGrams(token, 4)) {
        _accumulateFeature(vector, ngram, 0.45 * positionWeight * scale);
      }
      if (i + 1 < tokens.length) {
        final bigram = '${tokens[i]}_${tokens[i + 1]}';
        _accumulateFeature(vector, bigram, 0.8 * positionWeight * scale);
      }
    }
  }

  bool _sameTokens(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
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

  Iterable<String> _characterNGrams(String token, int n) sync* {
    if (token.length < n) return;
    for (var i = 0; i <= token.length - n; i++) {
      yield token.substring(i, i + n);
    }
  }

  void _accumulateFeature(List<double> vector, String feature, double value) {
    if (feature.isEmpty) return;
    final hash = _stableHash(feature);
    final idx = hash % embeddingSize;
    vector[idx] += value;
  }

  int _stableHash(String input) {
    var hash = 2166136261;
    for (final unit in input.codeUnits) {
      hash ^= unit;
      hash = (hash * 16777619) & 0x7fffffff;
    }
    return hash.abs();
  }
}

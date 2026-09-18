import 'dart:math' as math;

import 'package:ai_orchestrator/features/semantic_index/workspace_embedding_service.dart';
import 'package:flutter_test/flutter_test.dart';

List<double> _legacyAsciiEmbedding(String text, int size) {
  final vector = List<double>.filled(size, 0);
  final normalized = text
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (normalized.isEmpty) return vector;

  final tokens = normalized
      .split(RegExp(r'[^a-z0-9_]+'))
      .where((token) => token.isNotEmpty)
      .toList(growable: false);
  if (tokens.isEmpty) return vector;

  int stableHash(String input) {
    var hash = 2166136261;
    for (final unit in input.codeUnits) {
      hash ^= unit;
      hash = (hash * 16777619) & 0x7fffffff;
    }
    return hash.abs();
  }

  void add(String feature, double value) {
    if (feature.isEmpty) return;
    vector[stableHash(feature) % size] += value;
  }

  Iterable<String> ngrams(String token, int n) sync* {
    if (token.length < n) return;
    for (var i = 0; i <= token.length - n; i++) {
      yield token.substring(i, i + n);
    }
  }

  for (var i = 0; i < tokens.length; i++) {
    final token = tokens[i];
    final positionWeight = 1.0 + (i / math.max(1, tokens.length));
    add(token, 1.0 * positionWeight);
    for (final ngram in ngrams(token, 3)) {
      add(ngram, 0.6 * positionWeight);
    }
    for (final ngram in ngrams(token, 4)) {
      add(ngram, 0.45 * positionWeight);
    }
    if (i + 1 < tokens.length) {
      add('${tokens[i]}_${tokens[i + 1]}', 0.8 * positionWeight);
    }
  }

  var norm = 0.0;
  for (final value in vector) {
    norm += value * value;
  }
  if (norm == 0) return vector;

  final denom = math.sqrt(norm);
  return vector.map((value) => value / denom).toList(growable: false);
}

void main() {
  const service = WorkspaceEmbeddingService();

  test('ASCII embeddings remain identical to the historical algorithm', () {
    const text = 'phi local model decision 123';

    expect(
      service.embedText(text),
      _legacyAsciiEmbedding(text, service.embeddingSize),
    );
  });

  test('accent-only Latin text now produces semantic features', () {
    final vector = service.embedText('é à ñ ç');

    expect(vector.any((value) => value != 0), isTrue);
  });

  test('non-Latin letters are preserved by Unicode tokenization', () {
    final vector = service.embedText('東京');

    expect(vector.any((value) => value != 0), isTrue);
  });

  test('punctuation-only text still produces an empty vector', () {
    final vector = service.embedText('... !!! ¿?');

    expect(vector.every((value) => value == 0), isTrue);
  });
}

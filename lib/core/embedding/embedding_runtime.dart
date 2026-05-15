import 'package:flutter/foundation.dart';

abstract interface class EmbeddingRuntime {
  Future<bool> initialize();
  Future<List<double>> generateEmbedding(String text);
  bool get isReady;
  String get providerName;
  Future<void> dispose();
}

class MockEmbeddingRuntime implements EmbeddingRuntime {
  static const int _embeddingDim = 128;

  bool _ready = false;

  @override
  String get providerName => 'mock-fallback';

  @override
  Future<bool> initialize() async {
    _ready = true;
    return true;
  }

  @override
  Future<List<double>> generateEmbedding(String text) async {
    debugPrint(
      '[EMBEDDING_READY] WARNING – mock embeddings — no real backend '
      '(text length: ${text.length})',
    );
    return List<double>.filled(_embeddingDim, 0.0);
  }

  @override
  bool get isReady => _ready;

  @override
  Future<void> dispose() async {
    _ready = false;
  }
}

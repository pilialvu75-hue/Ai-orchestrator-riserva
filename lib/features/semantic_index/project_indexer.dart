import 'dart:io';

import 'package:ai_orchestrator/features/code_context/code_chunker.dart';
import 'package:ai_orchestrator/features/semantic_index/semantic_workspace_index.dart';
import 'package:ai_orchestrator/features/semantic_index/workspace_embedding_service.dart';

class ProjectIndexer {
  ProjectIndexer({
    required CodeChunker codeChunker,
    required WorkspaceEmbeddingService embeddingService,
    required SemanticWorkspaceIndex semanticIndex,
  })  : _codeChunker = codeChunker,
        _embeddingService = embeddingService,
        _semanticIndex = semanticIndex;

  final CodeChunker _codeChunker;
  final WorkspaceEmbeddingService _embeddingService;
  final SemanticWorkspaceIndex _semanticIndex;

  Future<void> indexWorkspace({
    required String workspaceId,
    required String rootPath,
    List<String> allowedExtensions = const <String>[
      '.dart',
      '.kt',
      '.java',
      '.md',
      '.yaml',
      '.yml',
      '.json',
      '.txt',
    ],
  }) async {
    await _semanticIndex.clearWorkspace(workspaceId);
    final root = Directory(rootPath);
    if (!root.existsSync()) return;
    final entities = root.listSync(recursive: true, followLinks: false);
    for (final entity in entities) {
      if (entity is! File) continue;
      if (!_isAllowedFile(entity.path, allowedExtensions)) continue;
      final content = await entity.readAsString();
      final chunks = _codeChunker.chunkFile(
        documentPath: entity.path,
        content: content,
      );
      for (final chunk in chunks) {
        final embedding = _embeddingService.embedText(chunk.text);
        await _semanticIndex.upsertChunk(
          workspaceId: workspaceId,
          documentPath: chunk.documentPath,
          chunkIndex: chunk.chunkIndex,
          chunkText: chunk.text,
          vector: embedding,
        );
      }
    }
  }

  bool _isAllowedFile(String path, List<String> allowedExtensions) {
    final lower = path.toLowerCase();
    return allowedExtensions.any((ext) => lower.endsWith(ext));
  }
}


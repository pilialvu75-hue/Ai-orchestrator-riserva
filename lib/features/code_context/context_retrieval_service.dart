import 'package:ai_orchestrator/features/code_context/code_chunker.dart';
import 'package:ai_orchestrator/features/semantic_index/semantic_workspace_index.dart';
import 'package:ai_orchestrator/features/semantic_index/workspace_embedding_service.dart';

class ContextRetrievalService {
  ContextRetrievalService({
    required SemanticWorkspaceIndex index,
    required WorkspaceEmbeddingService embeddingService,
  })  : _index = index,
        _embeddingService = embeddingService;

  final SemanticWorkspaceIndex _index;
  final WorkspaceEmbeddingService _embeddingService;

  Future<List<CodeChunk>> retrieve({
    required String query,
    String? workspaceId,
    int topK = 6,
  }) async {
    final queryVector = _embeddingService.embedText(query);
    final matches = await _index.search(
      queryVector: queryVector,
      workspaceId: workspaceId,
      topK: topK,
    );
    return matches
        .map(
          (match) => CodeChunk(
            documentPath: match.documentPath,
            chunkIndex: match.chunkIndex,
            text: match.chunkText,
          ),
        )
        .toList(growable: false);
  }
}

import 'dart:convert';
import 'dart:math' as math;

import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/database/database_helper.dart';
import 'package:uuid/uuid.dart';

class SemanticChunkMatch {
  const SemanticChunkMatch({
    required this.documentPath,
    required this.chunkIndex,
    required this.chunkText,
    required this.score,
  });

  final String documentPath;
  final int chunkIndex;
  final String chunkText;
  final double score;
}

class SemanticWorkspaceIndex {
  SemanticWorkspaceIndex({
    required DatabaseHelper databaseHelper,
  }) : _databaseHelper = databaseHelper;

  static const _uuid = Uuid();
  final DatabaseHelper _databaseHelper;

  Future<void> upsertChunk({
    required String workspaceId,
    required String documentPath,
    required int chunkIndex,
    required String chunkText,
    required List<double> vector,
  }) async {
    await _databaseHelper.insertDocumentChunk(<String, dynamic>{
      AppConstants.colId: _uuid.v4(),
      AppConstants.colDocumentId: workspaceId,
      AppConstants.colDocumentPath: documentPath,
      AppConstants.colDocumentTitle: documentPath.split('/').last,
      AppConstants.colChunkIndex: chunkIndex,
      AppConstants.colChunkText: chunkText,
      AppConstants.colVectorJson: jsonEncode(vector),
      AppConstants.colTimestamp: DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> clearWorkspace(String workspaceId) {
    return _databaseHelper.clearDocumentChunksByDocumentId(workspaceId);
  }

  Future<List<SemanticChunkMatch>> search({
    required List<double> queryVector,
    String? workspaceId,
    int topK = 6,
  }) async {
    final rows = await _databaseHelper.getAllDocumentChunks(limit: 4000);
    final out = <SemanticChunkMatch>[];
    for (final row in rows) {
      if (workspaceId != null &&
          workspaceId.trim().isNotEmpty &&
          row[AppConstants.colDocumentId] != workspaceId) {
        continue;
      }
      final vectorJson = row[AppConstants.colVectorJson] as String? ?? '[]';
      final vector = _decodeVector(vectorJson);
      if (vector.length != queryVector.length) continue;
      final score = _cosineSimilarity(queryVector, vector);
      if (score <= 0) continue;
      out.add(
        SemanticChunkMatch(
          documentPath: row[AppConstants.colDocumentPath] as String? ?? '',
          chunkIndex: row[AppConstants.colChunkIndex] as int? ?? 0,
          chunkText: row[AppConstants.colChunkText] as String? ?? '',
          score: score,
        ),
      );
    }
    out.sort((a, b) => b.score.compareTo(a.score));
    if (out.length <= topK) return out;
    return out.sublist(0, topK);
  }

  List<double> _decodeVector(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) return const <double>[];
      return decoded
          .whereType<num>()
          .map((value) => value.toDouble())
          .toList(growable: false);
    } catch (_) {
      return const <double>[];
    }
  }

  double _cosineSimilarity(List<double> a, List<double> b) {
    var dot = 0.0;
    var normA = 0.0;
    var normB = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    if (normA <= 0 || normB <= 0) return 0;
    return dot / (math.sqrt(normA) * math.sqrt(normB));
  }
}

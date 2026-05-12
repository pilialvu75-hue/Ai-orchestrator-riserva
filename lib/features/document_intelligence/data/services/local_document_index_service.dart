import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/database/database_helper.dart';
import 'package:path/path.dart' as p;

class LocalDocumentMatch {
  const LocalDocumentMatch({
    required this.documentId,
    required this.documentPath,
    required this.documentTitle,
    required this.chunkText,
    required this.score,
  });

  final String documentId;
  final String documentPath;
  final String documentTitle;
  final String chunkText;
  final double score;
}

class LocalDocumentIndexService {
  LocalDocumentIndexService({required DatabaseHelper databaseHelper})
      : _databaseHelper = databaseHelper;

  static const int _vectorSize = 96;
  static const int _chunkSizeChars = 900;
  static const int _chunkOverlapChars = 180;

  final DatabaseHelper _databaseHelper;

  Future<int> indexDocument({
    required String filePath,
    String? documentId,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw ArgumentError('Document not found: $filePath');
    }

    final text = (await _readDocumentText(file)).trim();
    if (text.isEmpty) {
      throw const FormatException('No readable text content found in document.');
    }

    final resolvedDocumentId = documentId?.trim().isNotEmpty == true
        ? documentId!.trim()
        : _deriveDocumentId(file);
    final title = p.basename(file.path);
    final chunks = _chunkText(text);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final db = await _databaseHelper.database;

    await db.transaction((txn) async {
      await txn.delete(
        AppConstants.tableDocumentChunks,
        where:
            '${AppConstants.colDocumentId} = ? OR ${AppConstants.colDocumentPath} = ?',
        whereArgs: [resolvedDocumentId, file.path],
      );

      for (var i = 0; i < chunks.length; i++) {
        final vector = _embedText(chunks[i]);
        await txn.insert(
          AppConstants.tableDocumentChunks,
          {
            AppConstants.colId: '$resolvedDocumentId:$i',
            AppConstants.colDocumentId: resolvedDocumentId,
            AppConstants.colDocumentPath: file.path,
            AppConstants.colDocumentTitle: title,
            AppConstants.colChunkIndex: i,
            AppConstants.colChunkText: chunks[i],
            AppConstants.colVectorJson: jsonEncode(vector),
            AppConstants.colTimestamp: timestamp,
          },
        );
      }
    });

    return chunks.length;
  }

  Future<List<LocalDocumentMatch>> search(
    String query, {
    int limit = 6,
  }) async {
    final normalized = query.trim();
    if (normalized.isEmpty || limit <= 0) return const [];

    final queryVector = _embedText(normalized);
    final rows = await _databaseHelper.getAllDocumentChunks(limit: 4000);

    final scored = <LocalDocumentMatch>[];
    for (final row in rows) {
      final vectorRaw = row[AppConstants.colVectorJson] as String? ?? '[]';
      final vector = _parseVector(vectorRaw);
      if (vector.isEmpty) continue;
      final score = _cosineSimilarity(queryVector, vector);
      if (score <= 0) continue;

      scored.add(
        LocalDocumentMatch(
          documentId: row[AppConstants.colDocumentId] as String? ?? '',
          documentPath: row[AppConstants.colDocumentPath] as String? ?? '',
          documentTitle: row[AppConstants.colDocumentTitle] as String? ?? '',
          chunkText: row[AppConstants.colChunkText] as String? ?? '',
          score: score,
        ),
      );
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(limit).toList(growable: false);
  }

  Future<String> _readDocumentText(File file) async {
    final ext = p.extension(file.path).toLowerCase();
    if (ext == '.pdf') {
      final bytes = await file.readAsBytes();
      return _extractPdfText(bytes);
    }
    return file.readAsString();
  }

  String _extractPdfText(List<int> bytes) {
    final payload = latin1.decode(bytes, allowInvalid: true);
    final matches = RegExp(r'[\x20-\x7E]{5,}')
        .allMatches(payload)
        .map((m) => m.group(0) ?? '')
        .where((s) => s.trim().isNotEmpty)
        .toList(growable: false);
    return matches.join('\n');
  }

  String _deriveDocumentId(File file) {
    final path = file.path.toLowerCase();
    final fileStamp = file.lengthSync() ^ file.lastModifiedSync().millisecondsSinceEpoch;
    final seed = '$path::$fileStamp';
    return 'doc_${seed.hashCode.abs()}';
  }

  List<String> _chunkText(String text) {
    final chunks = <String>[];
    var start = 0;
    while (start < text.length) {
      final end = math.min(start + _chunkSizeChars, text.length);
      final chunk = text.substring(start, end).trim();
      if (chunk.isNotEmpty) chunks.add(chunk);
      if (end >= text.length) break;
      start = math.max(0, end - _chunkOverlapChars);
    }
    return chunks;
  }

  List<double> _embedText(String text) {
    final vector = List<double>.filled(_vectorSize, 0);
    final tokens = RegExp(r"[a-zA-Z0-9_']+")
        .allMatches(text.toLowerCase())
        .map((m) => m.group(0)!)
        .where((token) => token.length >= 2);

    for (final token in tokens) {
      final hash = token.hashCode & 0x7fffffff;
      final idx = hash % _vectorSize;
      final sign = (hash & 1) == 0 ? 1.0 : -1.0;
      vector[idx] += sign;
    }

    final norm = math.sqrt(vector.fold<double>(0, (sum, v) => sum + (v * v)));
    if (norm == 0) return vector;
    for (var i = 0; i < vector.length; i++) {
      vector[i] = vector[i] / norm;
    }
    return vector;
  }

  List<double> _parseVector(String jsonVector) {
    try {
      final parsed = jsonDecode(jsonVector) as List<dynamic>;
      return parsed
          .map((value) => (value as num?)?.toDouble() ?? 0)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  double _cosineSimilarity(List<double> a, List<double> b) {
    final len = math.min(a.length, b.length);
    if (len == 0) return 0;
    var dot = 0.0;
    var normA = 0.0;
    var normB = 0.0;
    for (var i = 0; i < len; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    if (normA == 0 || normB == 0) return 0;
    return dot / (math.sqrt(normA) * math.sqrt(normB));
  }
}

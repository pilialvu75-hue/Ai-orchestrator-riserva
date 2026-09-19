import 'dart:io';

import 'package:ai_orchestrator/core/database/database_helper.dart';
import 'package:ai_orchestrator/features/semantic_index/semantic_workspace_index.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('workspace search returns only chunks from requested workspace', () async {
    final db = DatabaseHelper.instance;
    final index = SemanticWorkspaceIndex(databaseHelper: db);
    const workspaceA = 'semantic-scope-test-a';
    const workspaceB = 'semantic-scope-test-b';

    await index.clearWorkspace(workspaceA);
    await index.clearWorkspace(workspaceB);

    try {
      await index.upsertChunk(
        workspaceId: workspaceA,
        documentPath: '/a.txt',
        documentTitle: 'A',
        chunkIndex: 1,
        chunkText: 'alpha',
        vector: const <double>[1, 0, 0],
      );
      await index.upsertChunk(
        workspaceId: workspaceB,
        documentPath: '/b.txt',
        documentTitle: 'B',
        chunkIndex: 1,
        chunkText: 'beta',
        vector: const <double>[1, 0, 0],
      );

      final matches = await index.search(
        queryVector: const <double>[1, 0, 0],
        workspaceId: workspaceA,
        topK: 10,
      );

      expect(matches, hasLength(1));
      expect(matches.single.documentPath, '/a.txt');
      expect(matches.single.chunkText, 'alpha');
    } finally {
      await index.clearWorkspace(workspaceA);
      await index.clearWorkspace(workspaceB);
    }
  });

  test('workspace search uses scoped SQL query instead of global scan', () {
    final dbSource =
        File('lib/core/database/database_helper.dart').readAsStringSync();
    final indexSource = File(
      'lib/features/semantic_index/semantic_workspace_index.dart',
    ).readAsStringSync();

    expect(dbSource, contains('getDocumentChunksByDocumentId'));
    expect(
      indexSource,
      contains('await _databaseHelper.getDocumentChunksByDocumentId'),
    );
  });
}

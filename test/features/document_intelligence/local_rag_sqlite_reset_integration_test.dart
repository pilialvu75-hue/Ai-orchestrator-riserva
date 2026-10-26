import 'dart:io';

import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/database/database_helper.dart';
import 'package:ai_orchestrator/features/document_intelligence/data/services/local_document_index_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// End-to-end local RAG tests. In-memory SQLite and temporary source files
/// guarantee no user app database or project is modified.
void main() {
  late Database database;
  late DatabaseHelper helper;
  late Directory documents;
  late LocalDocumentIndexService index;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await database.execute('''
      CREATE TABLE document_chunks (
        id TEXT PRIMARY KEY,
        document_id TEXT NOT NULL,
        document_path TEXT NOT NULL,
        document_title TEXT NOT NULL DEFAULT '',
        chunk_index INTEGER NOT NULL,
        chunk_text TEXT NOT NULL DEFAULT '',
        vector_json TEXT NOT NULL DEFAULT '[]',
        timestamp INTEGER NOT NULL
      )
    ''');
    helper = DatabaseHelper.forTesting(database);
    documents = await Directory.systemTemp.createTemp('aivexus-rag-test-');
    index = LocalDocumentIndexService(databaseHelper: helper);
  });

  tearDown(() async {
    await database.close();
    await documents.delete(recursive: true);
  });

  test('local document search works and deleting index preserves source',
      () async {
    final source = File(documents.path + '/sky.txt');
    await source.writeAsString(
      'La diffusione di Rayleigh spiega il cielo blu. '
      'Le molecole diffondono maggiormente le lunghezze d onda corte.',
    );
    expect(
      await index.indexDocument(filePath: source.path, documentId: 'doc:sky'),
      1,
    );
    final matches = await index.search('cielo Rayleigh');
    expect(matches, isNotEmpty);
    expect(matches.first.documentId, 'doc:sky');
    expect(matches.first.documentPath, source.path);

    expect(await helper.deleteAllDocumentAndProjectRagIndexes(), 1);
    expect(await index.search('cielo Rayleigh'), isEmpty);
    expect(await source.exists(), isTrue);
    expect(await source.readAsString(), contains('Rayleigh'));
  });

  test('RAG reset preserves chat embeddings and vice versa', () async {
    final source = File(documents.path + '/sky.txt');
    await source.writeAsString('Rayleigh cielo azzurro');
    await index.indexDocument(filePath: source.path, documentId: 'doc:sky');

    await helper.insertDocumentChunk(<String, dynamic>{
      AppConstants.colId: 'chat-1',
      AppConstants.colDocumentId: 'chat_memory:session-one',
      AppConstants.colDocumentPath: 'chat://session-one/1',
      AppConstants.colDocumentTitle: 'chat',
      AppConstants.colChunkIndex: 1,
      AppConstants.colChunkText: 'Memoria sintetica',
      AppConstants.colVectorJson: '[]',
      AppConstants.colTimestamp: 1,
    });

    expect(await helper.deleteAllDocumentAndProjectRagIndexes(), 1);
    var rows = await helper.getAllDocumentChunks();
    expect(rows, hasLength(1));
    expect(rows.single[AppConstants.colDocumentId], 'chat_memory:session-one');

    await index.indexDocument(filePath: source.path, documentId: 'doc:sky');
    expect(await helper.deleteAllChatSemanticMemory(), 1);
    rows = await helper.getAllDocumentChunks();
    expect(rows, hasLength(1));
    expect(rows.single[AppConstants.colDocumentId], 'doc:sky');
    expect(await source.exists(), isTrue);
  });

  test('chat namespace matches literal underscore, not a wildcard', () async {
    for (final id in <String>[
      'chat_memory:real',
      'chatXmemory:similar-but-not-chat',
    ]) {
      await helper.insertDocumentChunk(<String, dynamic>{
        AppConstants.colId: id,
        AppConstants.colDocumentId: id,
        AppConstants.colDocumentPath: 'synthetic',
        AppConstants.colDocumentTitle: 'synthetic',
        AppConstants.colChunkIndex: 0,
        AppConstants.colChunkText: 'test',
        AppConstants.colVectorJson: '[]',
        AppConstants.colTimestamp: 1,
      });
    }
    expect(await helper.deleteAllChatSemanticMemory(), 1);
    final rows = await helper.getAllDocumentChunks();
    expect(rows, hasLength(1));
    expect(
      rows.single[AppConstants.colDocumentId],
      'chatXmemory:similar-but-not-chat',
    );
  });

  test('reindexing replaces outdated chunks', () async {
    final source = File(documents.path + '/notes.txt');
    await source.writeAsString('Il primo valore è 910');
    await index.indexDocument(filePath: source.path, documentId: 'doc:notes');

    await source.writeAsString('Il valore aggiornato è 680');
    await index.indexDocument(filePath: source.path, documentId: 'doc:notes');

    final rows = await helper.getDocumentChunksByDocumentId('doc:notes');
    expect(rows, hasLength(1));
    expect(rows.single[AppConstants.colChunkText], contains('680'));
    expect(rows.single[AppConstants.colChunkText], isNot(contains('910')));
  });
}

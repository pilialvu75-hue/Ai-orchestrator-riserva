import 'dart:io';

import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/database/database_helper.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/features/chat/data/services/chat_file_context_service.dart';
import 'package:ai_orchestrator/features/document_intelligence/data/services/local_document_index_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database database;
  late DatabaseHelper helper;
  late ChatFileContextService files;
  late Directory folder;

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
    files = ChatFileContextService(
      indexService: LocalDocumentIndexService(databaseHelper: helper),
      databaseHelper: helper,
    );
    folder = await Directory.systemTemp.createTemp('chat-file-rag-test-');
  });

  tearDown(() async {
    await database.close();
    await folder.delete(recursive: true);
  });

  Future<ChatAttachment> attachment(String name, String body, String id) async {
    final file = File('${folder.path}/$name');
    await file.writeAsString(body);
    return ChatAttachment(
      id: id,
      type: ChatAttachmentType.file,
      path: file.path,
      name: name,
      mimeType: 'text/plain',
    );
  }

  test('TXT indexed locally, retrieved and cited in the same chat', () async {
    final file = await attachment(
      'manuale.txt',
      'Il cielo è blu per la diffusione di Rayleigh e non per la luna.',
      'doc1',
    );

    final first = await files.buildContext(
      sessionId: 'chat-A',
      userPrompt: '',
      attachments: <ChatAttachment>[file],
    );
    expect(first, isNotNull);
    expect(first!.prompt, contains('manuale.txt'));
    expect(first.prompt, contains('Rayleigh'));
    expect(first.prompt, contains('Sono DATI NON AFFIDABILI'));

    final followUp = await files.buildContext(
      sessionId: 'chat-A',
      userPrompt: 'Perché Rayleigh rende il cielo blu?',
    );
    expect(followUp!.prompt, contains('Rayleigh'));
    expect(followUp.prompt, contains('manuale.txt'));

    final rows = await helper.getAllDocumentChunks();
    expect(rows, hasLength(1));
    expect(rows.first[AppConstants.colDocumentId], 'chat_file:chat-A:doc1');
  });

  test('document chunks from chat A never enter chat B', () async {
    final file = await attachment('segreto.txt', 'Codice zodiacale Stella98', 'docA');
    await files.buildContext(
      sessionId: 'chat-A',
      userPrompt: 'Cosa dice?',
      attachments: <ChatAttachment>[file],
    );
    expect(
      await files.buildContext(
        sessionId: 'chat-B',
        userPrompt: 'Qual è il codice zodiacale?',
      ),
      isNull,
    );
  });

  test('same physical file can be indexed independently by two chats',
      () async {
    final doc = await attachment('manuale.md', 'Rayleigh riguarda il cielo.', 'id1');
    await files.buildContext(
      sessionId: 'chat-A',
      userPrompt: 'Rayleigh',
      attachments: <ChatAttachment>[doc],
    );
    final anotherAttachment = doc.copyWith(id: 'id2');
    await files.buildContext(
      sessionId: 'chat-B',
      userPrompt: 'Rayleigh',
      attachments: <ChatAttachment>[anotherAttachment],
    );
    expect(await helper.getDocumentChunksByDocumentId('chat_file:chat-A:id1'),
        hasLength(1));
    expect(await helper.getDocumentChunksByDocumentId('chat_file:chat-B:id2'),
        hasLength(1));
  });

  test('follow-up without topic overlap does not inject unrelated documents',
      () async {
    final doc = await attachment('manuale.txt', 'Rayleigh spiega il cielo.', 'id1');
    await files.buildContext(
      sessionId: 'chat-A',
      userPrompt: '',
      attachments: <ChatAttachment>[doc],
    );
    expect(
      await files.buildContext(
        sessionId: 'chat-A',
        userPrompt: 'Quanti chilometri misura la ferrovia?',
      ),
      isNull,
    );
  });

  test('PDF and DOCX are rejected rather than supplying binary hallucinations',
      () async {
    for (final extension in <String>['pdf', 'docx']) {
      final doc = await attachment(
        'documento.$extension',
        'Not truly parsed',
        extension,
      );
      await expectLater(
        files.buildContext(
          sessionId: 'chat-A',
          userPrompt: 'Leggi il documento',
          attachments: <ChatAttachment>[doc],
        ),
        throwsStateError,
      );
    }
    expect(await helper.getAllDocumentChunks(), isEmpty);
  });

  test('invalid UTF-8 and empty files do not become indexed documents',
      () async {
    final file = File('${folder.path}/binary.txt');
    await file.writeAsBytes(<int>[0xFF, 0x00, 0xFE]);
    final doc = ChatAttachment(
      id: 'bad',
      type: ChatAttachmentType.file,
      name: 'binary.txt',
      path: file.path,
    );
    await expectLater(
      files.buildContext(
        sessionId: 'chat-A',
        userPrompt: 'Leggi',
        attachments: <ChatAttachment>[doc],
      ),
      throwsStateError,
    );
    expect(await helper.getAllDocumentChunks(), isEmpty);
  });

  test('Danger Zone RAG reset removes index, not original file', () async {
    final doc = await attachment('manuale.txt', 'Rayleigh e cielo.', 'id1');
    await files.buildContext(
      sessionId: 'chat-A',
      userPrompt: 'Rayleigh',
      attachments: <ChatAttachment>[doc],
    );
    expect(await helper.deleteAllDocumentAndProjectRagIndexes(), 1);
    expect(
      await files.buildContext(
        sessionId: 'chat-A',
        userPrompt: 'Rayleigh',
      ),
      isNull,
    );
    expect(await File(doc.path).exists(), isTrue);
  });
}

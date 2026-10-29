import 'dart:io';

import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/database/database_helper.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/features/chat/data/services/chat_file_context_service.dart';
import 'package:ai_orchestrator/features/chat/data/services/chat_local_pdf_text_service.dart';
import 'package:ai_orchestrator/features/document_intelligence/data/services/local_document_index_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database database;
  late DatabaseHelper helper;
  late ChatFileContextService files;
  late Directory folder;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
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

  test('unsupported DOCX and unavailable PDF parser fail without indexing',
      () async {
    final docx = await attachment('documento.docx', 'Not truly parsed', 'docx');
    await expectLater(
      files.buildContext(
        sessionId: 'chat-A',
        userPrompt: 'Leggi il documento',
        attachments: <ChatAttachment>[docx],
      ),
      throwsStateError,
    );

    // Explicit failure of the local PDF parser: the binary payload must
    // never enter RAG as fake text or be sent to a provider.
    final pdf = await attachment('documento.pdf', '%PDF-fake', 'pdf');
    final unavailablePdf = ChatFileContextService(
      indexService: LocalDocumentIndexService(databaseHelper: helper),
      databaseHelper: helper,
      pdfReader: _PdfStub('', failure: true),
    );
    await expectLater(
      unavailablePdf.buildContext(
        sessionId: 'chat-A',
        userPrompt: 'Leggi il documento',
        attachments: <ChatAttachment>[pdf],
      ),
      throwsStateError,
    );
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
  test('PDF extracted by a trusted local adapter is indexed and cited', () async {
    final pdf = await attachment('facture.pdf', '%PDF-fake', 'pdf1');
    final reader = _PdfStub(
      'Pagina 1: facture n. 2048\n'
      'Ligne en français: ça coûte 12,50 €.\n'
      'Teiera rossa: 24,00 €.\n',
    );
    final pdfFiles = ChatFileContextService(
      indexService: LocalDocumentIndexService(databaseHelper: helper),
      databaseHelper: helper,
      pdfReader: reader,
    );
    final result = await pdfFiles.buildContext(
      sessionId: 'chat-A',
      userPrompt: 'Qual è il prezzo della teiera?',
      attachments: <ChatAttachment>[pdf],
    );
    expect(result!.prompt, contains('facture.pdf'));
    expect(result.prompt, contains('Teiera rossa: 24,00 €'));
    expect(reader.paths, hasLength(1));
    final chunks = await helper.getAllDocumentChunks();
    expect(chunks, hasLength(1));
    expect(chunks.single[AppConstants.colDocumentTitle], 'facture.pdf');
    expect(chunks.single[AppConstants.colDocumentPath], pdf.path);

    // The same page stays available to subsequent queries in the same chat.
    final followUp = await pdfFiles.buildContext(
      sessionId: 'chat-A',
      userPrompt: 'Quanto costa la teiera?',
    );
    expect(followUp!.prompt, contains('facture.pdf'));
    expect(await pdfFiles.buildContext(
      sessionId: 'chat-B',
      userPrompt: 'Teiera',
    ), isNull);
  });

  test('LOCAL PDF prompt stays compact while SQLite retains all text', () async {
    final pdf = await attachment('AIVEXUS_Test_PDF_S24.pdf', '%PDF-fake', 'local');
    final entireDocument = '[Pagina 1/1]\n'
        'AIVEXUS / DOCUMENTO CAMPIONE\n';
    final rawPdfText = entireDocument +
        List.generate(100, (i) => 'Descrizione generale $i di un articolo.').join('\n') +
        '\n04 / TABELLA DI CONTROLLO\n'
        'ARTICOLO Q.TÀ PREZZO CODICE\n'
        'Teiera rossa 1 24,00 € TR-07';
    final localFiles = ChatFileContextService(
      indexService: LocalDocumentIndexService(databaseHelper: helper),
      databaseHelper: helper,
      pdfReader: _PdfStub(rawPdfText),
    );
    const question = 'Qual è il prezzo della teiera rossa, '
        'la quantità e il codice? Cita la pagina.';
    final context = await localFiles.buildContext(
      sessionId: 'chat-A',
      userPrompt: question,
      attachments: <ChatAttachment>[pdf],
      compactForLocal: true,
    );
    expect(context, isNotNull);
    expect(context!.prompt, contains('Teiera rossa 1 24,00 € TR-07'));
    expect(context.prompt, contains('Quantità: 1; Prezzo: 24,00 €; Codice: TR-07'));
    expect(context.prompt, contains('Pagina del documento: [Pagina 1/1]'));
    expect(context.prompt, contains('AIVEXUS_Test_PDF_S24.pdf'));
    expect(context.prompt.length, lessThan(1500));
    final saved = await helper.getAllDocumentChunks();
    expect(saved, isNotEmpty);
    expect(saved.map((row) => row[AppConstants.colChunkText]).join(' '),
        contains('Teiera rossa 1 24,00 € TR-07'));
    // Compacting the prompt never truncates or deletes the indexed document.
    expect(saved.length, greaterThan(2));
  });

  test('explicit table formatting request adds compact Markdown instruction',
      () async {
    final file = await attachment('tabella.txt',
        'ARTICOLO Q.TÀ PREZZO CODICE\n'
        'Tazza blu 1 8,90 € TZ-19', 'table');
    final normal = await files.buildContext(
      sessionId: 'table-chat',
      userPrompt: 'Qual è il prezzo della Tazza blu?',
      attachments: [file],
      compactForLocal: true,
    );
    expect(normal!.prompt, isNot(contains('Formato richiesto:')));

    final formatted = await files.buildContext(
      sessionId: 'table-chat',
      userPrompt: 'Riporta i dati della Tazza blu in una tabella Markdown.',
      compactForLocal: true,
    );
    expect(formatted, isNotNull);
    expect(formatted!.prompt, contains('Tabella Markdown: a capo dopo ogni riga'));
    expect(formatted.prompt, contains('non inventare celle'));
    expect(formatted.prompt, contains('Tazza blu 1 8,90 € TZ-19'));
    expect(formatted.prompt.length, lessThan(1500));
  });

  test('PDF follow-up asks Tazza quantity without reattaching the file',
      () async {
    final pdf = await attachment('AIVEXUS_Test_PDF_S24.pdf', '%PDF-fake', 'pdf1');
    final pdfFiles = ChatFileContextService(
      indexService: LocalDocumentIndexService(databaseHelper: helper),
      databaseHelper: helper,
      pdfReader: _PdfStub('[Pagina 1/1]\n'
          'ARTICOLO Q.TÀ PREZZO CODICE\n'
          'Thé vert 2 4,50 € TV-02\n'
          'Tazza blu 1 8,90 € TZ-19\n'
          'Teiera rossa 1 24,00 € TR-07'),
    );
    final first = await pdfFiles.buildContext(
      sessionId: 'fresh-chat',
      userPrompt: 'Prezzo e codice della teiera rossa',
      attachments: <ChatAttachment>[pdf],
      compactForLocal: true,
    );
    expect(first!.prompt, contains('Teiera rossa 1 24,00 € TR-07'));

    final second = await pdfFiles.buildContext(
      sessionId: 'fresh-chat',
      userPrompt: 'Qual è la quantità e il codice della Tazza blu?',
      compactForLocal: true,
    );
    expect(second, isNotNull);
    expect(second!.prompt, contains('Articolo: Tazza blu; Quantità: 1; '
        'Prezzo: 8,90 €; Codice: TZ-19.'));
    expect(second.prompt, contains('Pagina del documento: [Pagina 1/1]'));
    expect(second.prompt, isNot(contains('Quantità: 2;')));
    expect(second.prompt.length, lessThan(1500));
  });

  test('selected PDF ignores old attachments in the same chat', () async {
    final first = await attachment('old.pdf', '%PDF-a', 'first');
    final second = await attachment('new.pdf', '%PDF-b', 'second');
    final older = ChatFileContextService(
      indexService: LocalDocumentIndexService(databaseHelper: helper),
      databaseHelper: helper,
      pdfReader: _PdfStub('[Pagina 1/1]\nVecchio prezzo 999,00 €'),
    );
    await older.buildContext(
      sessionId: 'chat-A',
      userPrompt: 'prezzo',
      attachments: [first],
      compactForLocal: true,
    );
    final newer = ChatFileContextService(
      indexService: LocalDocumentIndexService(databaseHelper: helper),
      databaseHelper: helper,
      pdfReader: _PdfStub('[Pagina 1/1]\nTeiera rossa 1 24,00 € TR-07'),
    );
    final context = await newer.buildContext(
      sessionId: 'chat-A',
      userPrompt: 'prezzo teiera rossa codice',
      attachments: [second],
      compactForLocal: true,
    );
    expect(context!.prompt, contains('new.pdf'));
    expect(context.prompt, contains('24,00 €'));
    expect(context.prompt, isNot(contains('old.pdf')));
    expect(context.prompt, isNot(contains('999,00 €')));
    // The earlier document stays stored, only excluded from this prompt.
    expect(await helper.getAllDocumentChunks(), hasLength(2));
  });

  test('PDF reader failure never indexes binary or leaks into chat memory',
      () async {
    final pdf = await attachment('rotto.pdf', '%PDF-invalid', 'pdfbad');
    final pdfFiles = ChatFileContextService(
      indexService: LocalDocumentIndexService(databaseHelper: helper),
      databaseHelper: helper,
      pdfReader: _PdfStub('', failure: true),
    );
    await expectLater(
      pdfFiles.buildContext(
        sessionId: 'chat-A',
        userPrompt: 'Leggi PDF',
        attachments: [pdf],
      ),
      throwsStateError,
    );
    expect(await helper.getAllDocumentChunks(), isEmpty);
  });

  test('oversized PDF is rejected before invoking native reader',
      () async {
    final big = File('${folder.path}/large.pdf');
    await big.writeAsBytes(List<int>.filled(8 * 1024 * 1024 + 1, 65));
    final doc = ChatAttachment(
      id: 'big', type: ChatAttachmentType.file,
      path: big.path, name: 'large.pdf',
    );
    final reader = _PdfStub('Should not be called');
    final pdfFiles = ChatFileContextService(
      indexService: LocalDocumentIndexService(databaseHelper: helper),
      databaseHelper: helper,
      pdfReader: reader,
    );
    await expectLater(
      pdfFiles.buildContext(
        sessionId: 'chat-A',
        userPrompt: 'Leggi PDF', attachments: [doc],
      ), throwsStateError,
    );
    expect(reader.paths, isEmpty);
    expect(await helper.getAllDocumentChunks(), isEmpty);
  });

}

class _PdfStub implements PdfOfflineTextReader {
  _PdfStub(this.text, {this.failure = false});
  final String text;
  final bool failure;
  final List<String> paths = <String>[];

  @override
  Future<String> readPdf(String path) async {
    paths.add(path);
    if (failure) throw StateError('PDF intentionally invalid');
    return text;
  }
}

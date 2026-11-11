import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/database/database_helper.dart';
import 'package:sqflite/sqflite.dart';

/// Metadata only. An entry does NOT imply that a remote upload completed.
/// The encrypted transcript and attachment bytes are NEVER stored here.
class ChatArchivePointer {
  const ChatArchivePointer({
    required this.archiveId,
    required this.originDeviceId,
    required this.sourceSessionId,
    required this.storageProviderId,
    required this.objectKey,
    required this.ciphertextSha256,
    required this.ciphertextBytes,
    required this.messageCount,
    required this.indexedAtMs,
    this.remoteVerifiedAtMs,
  });

  final String archiveId;
  final String originDeviceId;
  final String sourceSessionId;
  final String storageProviderId;
  final String objectKey;
  final String ciphertextSha256;
  final int ciphertextBytes;
  final int messageCount;
  final int indexedAtMs;

  /// Null until a future storage adapter has independently downloaded
  /// and authenticated the remote ciphertext. No verification API yet.
  final int? remoteVerifiedAtMs;

  bool get isRemoteVerified => remoteVerifiedAtMs != null;

  Map<String, Object?> toRow() => <String, Object?>{
        'archive_id': archiveId,
        'origin_device_id': originDeviceId,
        'source_session_id': sourceSessionId,
        'storage_provider_id': storageProviderId,
        'object_key': objectKey,
        'ciphertext_sha256': ciphertextSha256,
        'ciphertext_bytes': ciphertextBytes,
        'message_count': messageCount,
        'indexed_at_ms': indexedAtMs,
        'remote_verified_at_ms': remoteVerifiedAtMs,
      };

  factory ChatArchivePointer.fromRow(Map<String, Object?> row) =>
      ChatArchivePointer(
        archiveId: row['archive_id'] as String,
        originDeviceId: row['origin_device_id'] as String,
        sourceSessionId: row['source_session_id'] as String,
        storageProviderId: row['storage_provider_id'] as String,
        objectKey: row['object_key'] as String,
        ciphertextSha256: row['ciphertext_sha256'] as String,
        ciphertextBytes: row['ciphertext_bytes'] as int,
        messageCount: row['message_count'] as int,
        indexedAtMs: row['indexed_at_ms'] as int,
        remoteVerifiedAtMs: row['remote_verified_at_ms'] as int?,
      );
}

/// A traceable connection from one confirmed memory to a source message.
/// It does not promote candidates or inject any data into inference.
class ChatArchiveMemoryLink {
  const ChatArchiveMemoryLink({
    required this.memoryScope,
    required this.memoryKey,
    required this.archiveId,
    required this.messageId,
  });

  final String memoryScope;
  final String memoryKey;
  final String archiveId;
  final String messageId;

  Map<String, Object> toRow() => <String, Object>{
        'memory_scope': memoryScope,
        'memory_key': memoryKey,
        'archive_id': archiveId,
        'message_id': messageId,
      };

  factory ChatArchiveMemoryLink.fromRow(Map<String, Object?> row) =>
      ChatArchiveMemoryLink(
        memoryScope: row['memory_scope'] as String,
        memoryKey: row['memory_key'] as String,
        archiveId: row['archive_id'] as String,
        messageId: row['message_id'] as String,
      );
}

/// Opt-in future distributed archive metadata index.
///
/// This first phase performs no file I/O, network access, eviction or
/// modification of the existing chat_history / durable memory records.
class ChatArchiveCatalog {
  ChatArchiveCatalog({required DatabaseHelper databaseHelper})
      : _databaseHelper = databaseHelper,
        _testDatabase = null;

  ChatArchiveCatalog.forTesting(Database db)
      : _databaseHelper = null,
        _testDatabase = db;

  final DatabaseHelper? _databaseHelper;
  final Database? _testDatabase;

  Future<Database> get _db async =>
      _testDatabase ?? await _databaseHelper!.database;

  Future<void> addPendingPointer(ChatArchivePointer pointer) async {
    _validatePointer(pointer);
    if (pointer.remoteVerifiedAtMs != null) {
      throw ArgumentError('Remote verification cannot be claimed by catalog');
    }
    final db = await _db;
    await db.transaction((txn) async {
      final rows = await txn.query(
        AppConstants.tableChatArchiveCatalog,
        where: 'archive_id = ?',
        whereArgs: <Object>[pointer.archiveId],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        final existing = ChatArchivePointer.fromRow(rows.single);
        if (existing.originDeviceId != pointer.originDeviceId ||
            existing.sourceSessionId != pointer.sourceSessionId ||
            existing.storageProviderId != pointer.storageProviderId ||
            existing.objectKey != pointer.objectKey ||
            existing.ciphertextSha256 != pointer.ciphertextSha256 ||
            existing.ciphertextBytes != pointer.ciphertextBytes ||
            existing.messageCount != pointer.messageCount) {
          throw StateError('Archive ID collision or attempted rewrite');
        }
        // Immutable snapshot. In particular, never overwrite verification.
        return;
      }
      await txn.insert(
        AppConstants.tableChatArchiveCatalog,
        pointer.toRow(),
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
    });
  }

  Future<ChatArchivePointer?> findPointer(String archiveId) async {
    final rows = await (await _db).query(
      AppConstants.tableChatArchiveCatalog,
      where: 'archive_id = ?',
      whereArgs: <Object>[archiveId],
      limit: 1,
    );
    return rows.isEmpty ? null : ChatArchivePointer.fromRow(rows.single);
  }

  Future<List<ChatArchivePointer>> findByOrigin({
    required String originDeviceId,
    required String sessionId,
  }) async {
    final rows = await (await _db).query(
      AppConstants.tableChatArchiveCatalog,
      where: 'origin_device_id = ? AND source_session_id = ?',
      whereArgs: <Object>[originDeviceId, sessionId],
      orderBy: 'indexed_at_ms DESC, archive_id DESC',
    );
    return List<ChatArchivePointer>.unmodifiable(
      rows.map(ChatArchivePointer.fromRow),
    );
  }

  Future<void> addMemorySource(ChatArchiveMemoryLink link) async {
    _requireId(link.memoryScope, 'memoryScope');
    _requireId(link.memoryKey, 'memoryKey');
    _requireId(link.archiveId, 'archiveId');
    _requireId(link.messageId, 'messageId');
    final db = await _db;
    await db.transaction((txn) async {
      final rows = await txn.query(
        AppConstants.tableChatArchiveCatalog,
        columns: const <String>['archive_id'],
        where: 'archive_id = ?',
        whereArgs: <Object>[link.archiveId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Unknown archive source');
      await txn.insert(
        AppConstants.tableChatArchiveMemoryLinks,
        link.toRow(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    });
  }

  Future<List<ChatArchiveMemoryLink>> sourcesForMemory({
    required String memoryScope,
    required String memoryKey,
  }) async {
    final rows = await (await _db).query(
      AppConstants.tableChatArchiveMemoryLinks,
      where: 'memory_scope = ? AND memory_key = ?',
      whereArgs: <Object>[memoryScope, memoryKey],
      orderBy: 'archive_id, message_id',
    );
    return List<ChatArchiveMemoryLink>.unmodifiable(
      rows.map(ChatArchiveMemoryLink.fromRow),
    );
  }

  static void _validatePointer(ChatArchivePointer pointer) {
    _requireId(pointer.archiveId, 'archiveId');
    _requireId(pointer.originDeviceId, 'originDeviceId');
    _requireId(pointer.sourceSessionId, 'sourceSessionId');
    _requireId(pointer.storageProviderId, 'storageProviderId');
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(pointer.ciphertextSha256)) {
      throw ArgumentError('Expected a lowercase SHA-256 ciphertext digest');
    }
    final key = pointer.objectKey;
    if (key.isEmpty ||
        key.length > 1024 ||
        key.startsWith('/') ||
        key.endsWith('/') ||
        key.contains('://') ||
        key.contains('\\') ||
        key.contains('?') ||
        key.contains('#') ||
        key.split('/').any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw ArgumentError('Expected an opaque, relative archive object key');
    }
    if (pointer.ciphertextBytes <= 0 ||
        pointer.messageCount < 0 ||
        pointer.indexedAtMs < 0) {
      throw ArgumentError('Invalid archive size/count/timestamp');
    }
  }

  static void _requireId(String value, String field) {
    if (value.trim() != value ||
        value.isEmpty ||
        value.length > 160 ||
        value.contains('\n') ||
        value.contains('\r')) {
      throw ArgumentError('Invalid ' + field);
    }
  }
}

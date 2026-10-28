import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/database/database_helper.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

/// A new conversation never deletes the history of earlier conversations.
class ChatSessionInfo {
  const ChatSessionInfo({
    required this.id,
    required this.title,
    required this.lastActivity,
    required this.pinned,
  });
  final String id;
  final String title;
  final int lastActivity;
  final bool pinned;
}

class ChatSessionStore {
  ChatSessionStore({required DatabaseHelper databaseHelper})
      : _databaseHelper = databaseHelper,
        _testDatabase = null;

  /// Unit tests inject an in-memory database; never use real user data.
  ChatSessionStore.forTesting(Database database)
      : _databaseHelper = null,
        _testDatabase = database;

  static const String defaultSessionId = 'default';
  static const String activeSessionPreference = 'assistant.chat.active_session';
  static const String _titlePreferencePrefix = 'assistant.chat.title.';
  static const String _trashPreferencePrefix = 'assistant.chat.trash.';
  final DatabaseHelper? _databaseHelper;
  final Database? _testDatabase;

  Future<Database> get _database async =>
      _testDatabase ?? await _databaseHelper!.database;

  Future<String?> _getActivePreference() async {
    final db = await _database;
    final rows = await db.query(
      AppConstants.tableUserPreferences,
      where: '${AppConstants.colPrefKey} = ?',
      whereArgs: const <String>[activeSessionPreference],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first[AppConstants.colPrefValue] as String?;
  }

  Future<String> restoreActiveSession() async {
    final saved = await _getActivePreference();
    final sessions = await listSessions();
    if (saved != null && sessions.any((item) => item.id == saved)) {
      return saved;
    }
    if (sessions.isEmpty) {
      // The default conversation may still exist in the reversible trash.
      // Never resurrect it by silently reusing its identifier.
      final defaultTrashed = (await listSessions(inTrash: true))
          .any((item) => item.id == defaultSessionId);
      final newId = defaultTrashed ? const Uuid().v4() : defaultSessionId;
      await createSession(newId);
      await selectSession(newId);
      return newId;
    }
    final restored = sessions.first.id;
    await selectSession(restored);
    return restored;
  }

  Future<void> createSession(String sessionId) async {
    final id = sessionId.trim();
    if (id.isEmpty) throw ArgumentError('Session id must not be empty');
    final db = await _database;
    await db.insert(
      AppConstants.tableChatSessions,
      <String, Object>{
        'id': id,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'pinned': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> selectSession(String sessionId) async {
    final db = await _database;
    await db.insert(
      AppConstants.tableUserPreferences,
      <String, Object>{
        AppConstants.colPrefKey: activeSessionPreference,
        AppConstants.colPrefValue: sessionId,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> setPinned(String sessionId, bool pinned) async {
    final db = await _database;
    await db.update(
      AppConstants.tableChatSessions,
      <String, Object>{'pinned': pinned ? 1 : 0},
      where: 'id = ?',
      whereArgs: <Object>[sessionId],
    );
  }

  /// Persist a user-provided title without changing the original message.
  /// Existing SQLite databases already contain user_preferences: no migration.
  Future<void> renameSession(String sessionId, String title) async {
    final normalized = title.trim();
    if (normalized.isEmpty || normalized.length > 80) {
      throw ArgumentError('Chat title must contain 1 to 80 characters');
    }
    final db = await _database;
    await db.transaction((txn) async {
      final existing = await txn.query(
        AppConstants.tableChatSessions,
        columns: const <String>['id'],
        where: 'id = ?',
        whereArgs: <String>[sessionId],
        limit: 1,
      );
      if (existing.isEmpty) throw StateError('Chat session not found');
      await txn.insert(
        AppConstants.tableUserPreferences,
        <String, Object>{
          AppConstants.colPrefKey: '$_titlePreferencePrefix$sessionId',
          AppConstants.colPrefValue: normalized,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  /// A reversible, per-session trash marker. Messages, titles, attachments
  /// and semantic indexes are never removed by this operation.
  Future<void> moveToTrash(String sessionId) async {
    final db = await _database;
    await db.transaction((txn) async {
      final session = await txn.query(
        AppConstants.tableChatSessions,
        columns: const <String>['id'],
        where: 'id = ?',
        whereArgs: <String>[sessionId],
        limit: 1,
      );
      if (session.isEmpty) throw StateError('Chat session not found');
      await txn.insert(
        AppConstants.tableUserPreferences,
        <String, Object>{
          AppConstants.colPrefKey: '$_trashPreferencePrefix$sessionId',
          AppConstants.colPrefValue:
              DateTime.now().millisecondsSinceEpoch.toString(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  Future<void> restoreFromTrash(String sessionId) async {
    final db = await _database;
    await db.delete(
      AppConstants.tableUserPreferences,
      where: '${AppConstants.colPrefKey} = ?',
      whereArgs: <String>['$_trashPreferencePrefix$sessionId'],
    );
  }

  /// Pinned sessions first, then most recent. User titles override titles
  /// derived from the first message; the original message is never edited.
  Future<List<ChatSessionInfo>> listSessions({bool inTrash = false}) async {
    final db = await _database;
    final rows = await db.rawQuery('''
      SELECT s.id, s.pinned,
             (SELECT t.${AppConstants.colPrefValue}
              FROM ${AppConstants.tableUserPreferences} AS t
              WHERE t.${AppConstants.colPrefKey} = '$_trashPreferencePrefix' || s.id
              LIMIT 1) AS trash_marker,
             (SELECT p.${AppConstants.colPrefValue}
              FROM ${AppConstants.tableUserPreferences} AS p
              WHERE p.${AppConstants.colPrefKey} = '$_titlePreferencePrefix' || s.id
              LIMIT 1) AS custom_title,
             COALESCE(
               (SELECT MAX(m.${AppConstants.colTimestamp})
                FROM ${AppConstants.tableChatHistory} AS m
                WHERE m.${AppConstants.colSessionId} = s.id),
               s.created_at
             ) AS last_activity,
             (SELECT m.${AppConstants.colContent}
              FROM ${AppConstants.tableChatHistory} AS m
              WHERE m.${AppConstants.colSessionId} = s.id
                AND m.${AppConstants.colRole} = 'user'
              ORDER BY m.${AppConstants.colTimestamp} ASC,
                       m.${AppConstants.colId} ASC
              LIMIT 1) AS first_prompt
      FROM ${AppConstants.tableChatSessions} AS s
      ORDER BY s.pinned DESC, last_activity DESC, s.id DESC
    ''');

    return rows.where((row) =>
        inTrash ? row['trash_marker'] != null : row['trash_marker'] == null
    ).map((row) {
      final firstPrompt = (row['first_prompt'] as String? ?? '')
          .trim()
          .replaceAll(RegExp(r'\s+'), ' ');
      final fallbackTitle = firstPrompt.isEmpty
          ? 'Nuova chat'
          : firstPrompt.length <= 65
              ? firstPrompt
              : '${firstPrompt.substring(0, 62)}...';
      final customTitle = (row['custom_title'] as String? ?? '').trim();
      final title = customTitle.isEmpty ? fallbackTitle : customTitle;
      return ChatSessionInfo(
        id: row['id'] as String,
        title: title,
        lastActivity: row['last_activity'] as int,
        pinned: row['pinned'] == 1,
      );
    }).toList(growable: false);
  }
}

import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/database/database_helper.dart';
import 'package:sqflite/sqflite.dart';

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
      : _databaseHelper = databaseHelper;
  static const String defaultSessionId = 'default';
  static const String activeSessionPreference = 'assistant.chat.active_session';
  final DatabaseHelper _databaseHelper;

  Future<String> restoreActiveSession() async {
    final saved = await _databaseHelper.getPreference(activeSessionPreference);
    final sessions = await listSessions();
    if (saved != null && sessions.any((item) => item.id == saved)) {
      return saved;
    }
    if (sessions.isEmpty) {
      await createSession(defaultSessionId);
      await selectSession(defaultSessionId);
      return defaultSessionId;
    }
    final restored = sessions.first.id;
    await selectSession(restored);
    return restored;
  }

  Future<void> createSession(String sessionId) async {
    final id = sessionId.trim();
    if (id.isEmpty) throw ArgumentError('Session id must not be empty');
    final db = await _databaseHelper.database;
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

  Future<void> selectSession(String sessionId) =>
      _databaseHelper.setPreference(activeSessionPreference, sessionId);

  Future<void> setPinned(String sessionId, bool pinned) async {
    final db = await _databaseHelper.database;
    await db.update(
      AppConstants.tableChatSessions,
      <String, Object>{'pinned': pinned ? 1 : 0},
      where: 'id = ?',
      whereArgs: <Object>[sessionId],
    );
  }

  /// Pinned sessions first, then most recent. Titles come only from the
  /// first user message rather than model-generated text.
  Future<List<ChatSessionInfo>> listSessions() async {
    final db = await _databaseHelper.database;
    final rows = await db.rawQuery('''
      SELECT s.id, s.pinned,
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

    return rows.map((row) {
      final firstPrompt = (row['first_prompt'] as String? ?? '')
          .trim()
          .replaceAll(RegExp(r'\s+'), ' ');
      final title = firstPrompt.isEmpty
          ? 'Nuova chat'
          : firstPrompt.length <= 65
              ? firstPrompt
              : '${firstPrompt.substring(0, 62)}...';
      return ChatSessionInfo(
        id: row['id'] as String,
        title: title,
        lastActivity: row['last_activity'] as int,
        pinned: row['pinned'] == 1,
      );
    }).toList(growable: false);
  }
}

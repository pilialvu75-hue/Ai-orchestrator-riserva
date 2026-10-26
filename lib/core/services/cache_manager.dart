import 'package:ai_orchestrator/core/database/database_helper.dart';

class CacheManager {
  const CacheManager();

  /// Chats are user content, not disposable cache. Automatic cleanup must
  /// never erase older conversations that the user expects to find in Chat.
  /// Explicit Clear Chat / Danger Zone remain the deletion entry points.
  Future<void> performCleanup(DatabaseHelper db) async {
    // No destructive cleanup of chat_history.
  }

  Future<Map<String, dynamic>> getCacheStats(DatabaseHelper db) async {
    final count = await db.countChatMessages();
    final database = await db.database;
    final rows = await database
        .rawQuery('SELECT MIN(timestamp) as oldest FROM chat_history');
    final oldestMillis =
        rows.isNotEmpty ? rows.first['oldest'] as int? : null;
    final oldestDate = oldestMillis != null
        ? DateTime.fromMillisecondsSinceEpoch(oldestMillis)
        : null;
    return {
      'messageCount': count,
      'oldestMessageDate': oldestDate?.toIso8601String(),
    };
  }
}

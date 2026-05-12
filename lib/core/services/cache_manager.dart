import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/database/database_helper.dart';

class CacheManager {
  const CacheManager();

  Future<void> performCleanup(DatabaseHelper db) async {
    final cutoff = DateTime.now()
        .subtract(const Duration(days: AppConstants.chatHistoryMaxAgeDays));
    await db.deleteOldChatMessages(cutoff);
    final remaining = await db.countChatMessages();
    if (remaining > AppConstants.chatHistoryMaxRows) {
      await db.deleteChatMessagesBeyondLimit(AppConstants.chatHistoryMaxRows);
    }
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

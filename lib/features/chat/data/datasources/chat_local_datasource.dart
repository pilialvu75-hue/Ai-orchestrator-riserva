import 'package:ai_orchestrator/core/database/database_helper.dart';
import 'package:ai_orchestrator/core/error/exceptions.dart';
import 'package:ai_orchestrator/features/chat/data/models/chat_message_model.dart';

abstract class ChatLocalDataSource {
  Future<void> insertMessage(ChatMessageModel message);
  Future<List<ChatMessageModel>> getMessages(String sessionId);
  Future<int> deleteOldMessages(DateTime cutoff);
  Future<int> countMessages();
  Future<int> deleteExcessMessages(int max);
  Future<int> clearSession(String sessionId);
}

class ChatLocalDataSourceImpl implements ChatLocalDataSource {
  const ChatLocalDataSourceImpl({required this.databaseHelper});

  final DatabaseHelper databaseHelper;

  @override
  Future<void> insertMessage(ChatMessageModel message) async {
    try {
      await databaseHelper.insertChatMessage(message.toMap());
    } catch (e) {
      throw DatabaseException('Failed to insert chat message: $e');
    }
  }

  @override
  Future<List<ChatMessageModel>> getMessages(String sessionId) async {
    try {
      final rows = await databaseHelper.getChatMessages(sessionId);
      return rows.map(ChatMessageModel.fromMap).toList();
    } catch (e) {
      throw DatabaseException('Failed to load chat messages: $e');
    }
  }

  @override
  Future<int> deleteOldMessages(DateTime cutoff) async {
    try {
      return databaseHelper.deleteOldChatMessages(cutoff);
    } catch (e) {
      throw DatabaseException('Failed to delete old messages: $e');
    }
  }

  @override
  Future<int> countMessages() async {
    try {
      return databaseHelper.countChatMessages();
    } catch (e) {
      throw DatabaseException('Failed to count messages: $e');
    }
  }

  @override
  Future<int> deleteExcessMessages(int max) async {
    try {
      return databaseHelper.deleteChatMessagesBeyondLimit(max);
    } catch (e) {
      throw DatabaseException('Failed to trim message history: $e');
    }
  }

  @override
  Future<int> clearSession(String sessionId) async {
    try {
      return databaseHelper.deleteChatSession(sessionId);
    } catch (e) {
      throw DatabaseException('Failed to clear session: $e');
    }
  }
}

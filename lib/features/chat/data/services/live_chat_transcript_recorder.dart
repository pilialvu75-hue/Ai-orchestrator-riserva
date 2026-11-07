import 'package:uuid/uuid.dart';

import 'package:ai_orchestrator/features/chat/data/datasources/chat_local_datasource.dart';
import 'package:ai_orchestrator/features/chat/data/models/chat_message_model.dart';

/// Persists recognized Live turns as ordinary messages in the active chat.
/// This stores text locally and does not submit a second inference request.
class LiveChatTranscriptRecorder {
  const LiveChatTranscriptRecorder({required ChatLocalDataSource localDataSource})
      : _localDataSource = localDataSource;

  final ChatLocalDataSource _localDataSource;

  Future<void> append({
    required String sessionId,
    required String role,
    required String text,
  }) async {
    if (role != 'user' && role != 'assistant') {
      throw ArgumentError.value(role, 'role', 'Only chat roles may be stored');
    }
    final normalizedId = sessionId.trim();
    if (normalizedId.isEmpty) {
      throw ArgumentError.value(sessionId, 'sessionId');
    }
    final normalizedText = text.trim();
    if (normalizedText.isEmpty) return;

    await _localDataSource.insertMessage(ChatMessageModel(
      id: const Uuid().v4(),
      sessionId: normalizedId,
      role: role,
      content: normalizedText,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      provider: 'live-local',
    ));
  }
}

import 'package:uuid/uuid.dart';

import 'package:ai_orchestrator/features/chat/data/datasources/chat_local_datasource.dart';
import 'package:ai_orchestrator/features/chat/data/models/chat_message_model.dart';

/// Records Live's already-recognized user text and generated assistant text
/// in the current local chat. Does not run another LLM request or use Cloud.
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
      throw ArgumentError.value(role, 'role', 'Expected user or assistant');
    }
    final normalizedId = sessionId.trim();
    if (normalizedId.isEmpty) {
      throw ArgumentError.value(sessionId, 'sessionId', 'Must not be empty');
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

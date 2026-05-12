import 'package:ai_orchestrator/core/orchestrator/state_engine/i_chat_repository.dart';

export '../../../../core/orchestrator/state_engine/i_chat_repository.dart';

abstract class ChatRepository implements IChatRepository {
  Future<void> clearSession(String sessionId);
}

import 'package:ai_orchestrator/core/orchestrator/state_engine/i_chat_repository.dart';

export '../../../../core/orchestrator/state_engine/i_chat_repository.dart';

abstract class ChatRepository implements IChatRepository {
  /// Application-verified local memory acknowledgement. The low-level
  /// implementation persists both turns without invoking an AI provider.
  /// Optional for legacy repositories; a trusted caller must fail closed if
  /// this capability is unavailable, not ask the LLM to invent the result.
  Future<ChatMessage?> persistVerifiedMemoryAction({
    required String sessionId,
    required String userPrompt,
    required String acknowledgement,
    void Function(String partialText)? onPartialResponse,
  }) async => null;

  @override
  Future<void> clearSession(String sessionId);

  @override
  Future<int> deleteMessagesFrom(
    String sessionId,
    String messageId,
  );
}

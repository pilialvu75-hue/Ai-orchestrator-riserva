import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';

/// Optional trusted capability for persisting a local memory action and its
/// authoritative acknowledgement as normal chat turns, without LLM inference.
///
/// This is deliberately NOT a method on the general ChatRepository interface:
/// specialized chat providers and fake repositories need not support it.
abstract interface class VerifiedMemoryActionWriter {
  Future<ChatMessage> persistVerifiedMemoryAction({
    required String sessionId,
    required String userPrompt,
    required String acknowledgement,
    void Function(String partialText)? onPartialResponse,
  });
}

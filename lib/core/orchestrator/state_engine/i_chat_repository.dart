import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';

/// Abstract contract for chat persistence + AI dispatch.
///
/// Defined in core so [OrchestratorStateEngine] depends only on the abstraction
/// without importing the features layer.
abstract class IChatRepository {
  Future<List<ChatMessage>> getMessages(String sessionId);

  Future<ChatMessage> sendMessage({
    required String sessionId,
    required String userPrompt,
    String? systemPrompt,
    List<ChatAttachment> attachments = const <ChatAttachment>[],
    void Function(String partialText)? onPartialResponse,
    void Function(String notice)? onRuntimeNotice,
  });

  Future<int> pruneHistory({
    int maxAgeDays,
    int maxRows,
  });
}

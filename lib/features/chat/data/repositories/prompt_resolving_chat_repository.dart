import 'package:ai_orchestrator/core/config/ai/assistant_interaction_prompt_resolver.dart';
import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/core/runtime/interaction/interaction_policy.dart';
import 'package:ai_orchestrator/features/chat/domain/repositories/chat_repository.dart';

/// Thin decorator that resolves the Assistant identity and presentation policy
/// before Local/Cloud routing begins.
///
/// Normal Chat is explicitly TEXT/GENERAL, which leaves the resolved base
/// prompt byte-for-byte unchanged. Other interaction channels use the same
/// resolver with a different [InteractionProfile].
class PromptResolvingChatRepository implements ChatRepository {
  const PromptResolvingChatRepository({
    required ChatRepository delegate,
    required AssistantInteractionPromptResolver promptResolver,
  })  : _delegate = delegate,
        _promptResolver = promptResolver;

  final ChatRepository _delegate;
  final AssistantInteractionPromptResolver _promptResolver;

  @override
  Future<List<ChatMessage>> getMessages(String sessionId) =>
      _delegate.getMessages(sessionId);

  @override
  Future<ChatMessage> sendMessage({
    required String sessionId,
    required String userPrompt,
    String? systemPrompt,
    List<ChatAttachment> attachments = const <ChatAttachment>[],
    void Function(String partialText)? onPartialResponse,
    void Function(String notice)? onRuntimeNotice,
  }) {
    return _delegate.sendMessage(
      sessionId: sessionId,
      userPrompt: userPrompt,
      systemPrompt: _promptResolver.resolve(
        incomingPrompt: systemPrompt,
        profile: InteractionProfile.text,
      ),
      attachments: attachments,
      onPartialResponse: onPartialResponse,
      onRuntimeNotice: onRuntimeNotice,
    );
  }

  @override
  Future<void> cancelActiveResponse(String sessionId) =>
      _delegate.cancelActiveResponse(sessionId);

  @override
  Future<int> pruneHistory({
    int maxAgeDays = AppConstants.chatHistoryMaxAgeDays,
    int maxRows = AppConstants.chatHistoryMaxRows,
  }) {
    return _delegate.pruneHistory(
      maxAgeDays: maxAgeDays,
      maxRows: maxRows,
    );
  }

  @override
  Future<void> clearSession(String sessionId) =>
      _delegate.clearSession(sessionId);

  @override
  Future<int> deleteMessagesFrom(
    String sessionId,
    String messageId,
  ) {
    return _delegate.deleteMessagesFrom(sessionId, messageId);
  }
}

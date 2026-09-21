import 'package:ai_orchestrator/core/config/ai/assistant_system_prompt_service.dart';
import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_context_service.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/features/chat/domain/repositories/chat_repository.dart';

/// Thin decorator that keeps Assistant prompt preference resolution outside the
/// persistence/runtime implementation.
///
/// All chat behavior is delegated unchanged except [sendMessage], where the
/// ordinary Assistant prompt marker is replaced with the user's configured
/// prompt before Local/Cloud routing begins.
class PromptResolvingChatRepository implements ChatRepository {
  const PromptResolvingChatRepository({
    required ChatRepository delegate,
    required AssistantSystemPromptService systemPromptService,
    required AssistantDurableMemoryContextService durableMemoryContextService,
  })  : _delegate = delegate,
        _systemPromptService = systemPromptService,
        _durableMemoryContextService = durableMemoryContextService;

  final ChatRepository _delegate;
  final AssistantSystemPromptService _systemPromptService;
  final AssistantDurableMemoryContextService _durableMemoryContextService;

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
  }) async {
    final isOrdinary =
        _systemPromptService.isOrdinaryAssistantRequest(systemPrompt);
    final resolvedPrompt = _systemPromptService.resolveForIncoming(systemPrompt);
    final effectivePrompt = isOrdinary
        ? await _durableMemoryContextService.augmentSystemPrompt(
            baseSystemPrompt: resolvedPrompt,
            sessionId: sessionId,
            userPrompt: userPrompt,
          )
        : resolvedPrompt;

    return _delegate.sendMessage(
      sessionId: sessionId,
      userPrompt: userPrompt,
      systemPrompt: effectivePrompt,
      attachments: attachments,
      onPartialResponse: onPartialResponse,
      onRuntimeNotice: onRuntimeNotice,
    );
  }

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

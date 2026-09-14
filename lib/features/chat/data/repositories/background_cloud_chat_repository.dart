import 'package:ai_orchestrator/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/core/runtime/background/cloud_background_execution.dart';
import 'package:ai_orchestrator/features/chat/domain/repositories/chat_repository.dart';

/// Decorates the existing chat pipeline with a platform background lease for
/// explicit Cloud mode only.
///
/// This class intentionally does not inspect or alter providers, prompts,
/// spending policy, failover, response streaming or persistence. It merely
/// keeps the Android process promoted while the existing [delegate] completes
/// the user-started Cloud send. Local and Hybrid routing remain untouched.
final class BackgroundCloudChatRepository implements ChatRepository {
  BackgroundCloudChatRepository({
    required ChatRepository delegate,
    required CloudBackgroundExecutionLease backgroundExecution,
    required bool Function() cloudModeActive,
  })  : _delegate = delegate,
        _backgroundExecution = backgroundExecution,
        _cloudModeActive = cloudModeActive;

  final ChatRepository _delegate;
  final CloudBackgroundExecutionLease _backgroundExecution;
  final bool Function() _cloudModeActive;

  int _nextLeaseSequence = 0;

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
    if (!_cloudModeActive()) {
      return _delegate.sendMessage(
        sessionId: sessionId,
        userPrompt: userPrompt,
        systemPrompt: systemPrompt,
        attachments: attachments,
        onPartialResponse: onPartialResponse,
        onRuntimeNotice: onRuntimeNotice,
      );
    }

    final leaseId = 'cloud-chat-${++_nextLeaseSequence}';
    await _backgroundExecution.acquire(leaseId);
    try {
      return await _delegate.sendMessage(
        sessionId: sessionId,
        userPrompt: userPrompt,
        systemPrompt: systemPrompt,
        attachments: attachments,
        onPartialResponse: onPartialResponse,
        onRuntimeNotice: onRuntimeNotice,
      );
    } finally {
      await _backgroundExecution.release(leaseId);
    }
  }

  @override
  Future<int> pruneHistory({
    int maxAgeDays = AppConstants.chatHistoryMaxAgeDays,
    int maxRows = AppConstants.chatHistoryMaxRows,
  }) =>
      _delegate.pruneHistory(
        maxAgeDays: maxAgeDays,
        maxRows: maxRows,
      );

  @override
  Future<void> clearSession(String sessionId) =>
      _delegate.clearSession(sessionId);

  @override
  Future<int> deleteMessagesFrom(
    String sessionId,
    String messageId,
  ) =>
      _delegate.deleteMessagesFrom(sessionId, messageId);
}

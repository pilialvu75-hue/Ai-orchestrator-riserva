import 'package:ai_orchestrator/core/memory/assistant_durable_memory_capture_service.dart';
import 'package:ai_orchestrator/features/chat/data/services/chat_session_store.dart';
import 'package:ai_orchestrator/features/chat_memory/conversation_memory_service.dart';

/// Coordinates an explicitly confirmed, irreversible purge of a trashed chat.
///
/// The three barriers work together:
/// - stop and drain durable memory capture;
/// - invalidate pending semantic embeddings for this conversation only;
/// - execute one SQLite transaction that preserves USER-scoped memories.
///
/// This is a storage-level service. No screen calls it yet: the eventual trash
/// UI must obtain fresh explicit user confirmation before calling this method.
class TrashedChatPurgeCoordinator {
  const TrashedChatPurgeCoordinator({
    required ChatSessionStore sessionStore,
    required ConversationMemoryService conversationMemoryService,
    required AssistantDurableMemoryCaptureService memoryCaptureService,
  })  : _sessionStore = sessionStore,
        _conversationMemoryService = conversationMemoryService,
        _memoryCaptureService = memoryCaptureService;

  final ChatSessionStore _sessionStore;
  final ConversationMemoryService _conversationMemoryService;
  final AssistantDurableMemoryCaptureService _memoryCaptureService;

  Future<int> purgeTrashedSession({
    required String sessionId,
    required bool userConfirmed,
  }) {
    if (!userConfirmed) {
      throw StateError('Permanent chat deletion needs user confirmation');
    }
    return _memoryCaptureService.runWithSessionPurgeBarrier(
      sessionId,
      () => _conversationMemoryService.runWithSessionPurgeBarrier(
        sessionId,
        () => _sessionStore.permanentlyDeleteTrashedSession(sessionId),
      ),
    );
  }
}

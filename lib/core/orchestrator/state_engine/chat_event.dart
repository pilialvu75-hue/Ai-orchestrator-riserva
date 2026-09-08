import 'package:equatable/equatable.dart';

import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';

/// Events dispatched to [OrchestratorStateEngine].
abstract class ChatEvent extends Equatable {
  const ChatEvent();

  @override
  List<Object?> get props => [];
}

class LoadMessagesEvent extends ChatEvent {
  const LoadMessagesEvent({required this.sessionId});

  final String sessionId;

  @override
  List<Object?> get props => [sessionId];
}

class SendMessageEvent extends ChatEvent {
  const SendMessageEvent({
    required this.sessionId,
    required this.userPrompt,
    this.systemPrompt,
    this.attachments = const <ChatAttachment>[],
  });

  final String sessionId;
  final String userPrompt;
  final String? systemPrompt;
  final List<ChatAttachment> attachments;

  @override
  List<Object?> get props => [sessionId, userPrompt, systemPrompt, attachments];
}

/// Modifica un messaggio utente esistente.
/// Rimuove il messaggio originale e tutti i messaggi successivi
/// (inclusa la risposta dell'assistente), poi reinvia il nuovo testo.
class EditMessageEvent extends ChatEvent {
  const EditMessageEvent({
    required this.sessionId,
    required this.originalMessageId,
    required this.newUserPrompt,
    this.attachments = const <ChatAttachment>[],
  });

  final String sessionId;
  final String originalMessageId;
  final String newUserPrompt;
  final List<ChatAttachment> attachments;

  @override
  List<Object?> get props => [
        sessionId,
        originalMessageId,
        newUserPrompt,
        attachments,
      ];
}

class PruneHistoryEvent extends ChatEvent {
  const PruneHistoryEvent();
}

class RecoverFromStuckUiEvent extends ChatEvent {
  const RecoverFromStuckUiEvent({
    required this.sessionId,
    required String runtimeMessage,
  }) : runtimeMessage =
            runtimeMessage ==
                    'Local runtime stalled before first token. Request cancelled and UI recovered.'
                ? 'Local runtime wait guard expired before first token. UI recovered; request cancellation was not confirmed.'
                : runtimeMessage;

  final String sessionId;

  /// UI recovery does not own the runtime cancellation token. Keep legacy
  /// callers source-compatible, but never surface the old message as proof
  /// that a request was cancelled when only the UI state was unlocked.
  final String runtimeMessage;

  @override
  List<Object?> get props => [sessionId, runtimeMessage];
}

class DebugClearChatEvent extends ChatEvent {
  const DebugClearChatEvent({required this.sessionId});

  final String sessionId;

  @override
  List<Object?> get props => [sessionId];
}

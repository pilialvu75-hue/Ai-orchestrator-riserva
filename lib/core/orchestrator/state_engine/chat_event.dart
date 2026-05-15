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

class PruneHistoryEvent extends ChatEvent {
  const PruneHistoryEvent();
}

class RecoverFromStuckUiEvent extends ChatEvent {
  const RecoverFromStuckUiEvent({
    required this.sessionId,
    required this.runtimeMessage,
  });

  final String sessionId;
  final String runtimeMessage;

  @override
  List<Object?> get props => [sessionId, runtimeMessage];
}

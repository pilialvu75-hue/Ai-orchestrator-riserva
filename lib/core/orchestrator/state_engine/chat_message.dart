import 'package:equatable/equatable.dart';

import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';

/// Core chat message entity.
///
/// Lives in [core/orchestrator/state_engine] so [OrchestratorStateEngine] can
/// reference it without importing from the features layer.
class ChatMessage extends Equatable {
  const ChatMessage({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.content,
    required this.timestamp,
    this.provider,
    this.attachments = const <ChatAttachment>[],
  });

  final String id;
  final String sessionId;
  final String role; // 'user' | 'assistant'
  final String content;
  final int timestamp;
  final String? provider;
  final List<ChatAttachment> attachments;

  @override
  List<Object?> get props => [
        id,
        sessionId,
        role,
        content,
        timestamp,
        provider,
        attachments,
      ];
}

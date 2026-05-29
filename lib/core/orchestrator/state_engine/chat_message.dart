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

  /// Returns true when this is an in-flight placeholder message created by the
  /// orchestrator before a real DB row has been written.  Placeholder IDs
  /// follow the convention [pending-assistant-*] / [pending-user-*].
  /// Used by the UI layer to render a typing indicator instead of empty text.
  bool get isPending => id.startsWith('pending-');

  /// Returns true for debug-lab injected messages that are not persisted to
  /// the database (id prefix: [debug-lab-]).
  bool get isDebugLabEntry => id.startsWith('debug-lab-');

  /// Creates a copy of this message with the given fields replaced.
  ///
  /// Streaming updates use this method to propagate accumulated [content]
  /// while keeping all other identity fields (id, sessionId, timestamp, …)
  /// unchanged.  This avoids the silent field-drop risk that exists when
  /// constructing a new [ChatMessage] manually inside every callback.
  ChatMessage copyWith({
    String? id,
    String? sessionId,
    String? role,
    String? content,
    int? timestamp,
    String? provider,
    List<ChatAttachment>? attachments,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      sessionId: sessionId ?? this.sessionId,
      role: role ?? this.role,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      provider: provider ?? this.provider,
      attachments: attachments ?? this.attachments,
    );
  }

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

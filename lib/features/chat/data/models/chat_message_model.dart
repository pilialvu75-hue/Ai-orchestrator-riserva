import 'dart:convert';

import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/features/chat/domain/entities/chat_message.dart';
import 'package:ai_orchestrator/core/config/app/app_constants.dart';

class ChatMessageModel extends ChatMessage {
  const ChatMessageModel({
    required super.id,
    required super.sessionId,
    required super.role,
    required super.content,
    required super.timestamp,
    super.provider,
    super.attachments,
  });

  factory ChatMessageModel.fromMap(Map<String, dynamic> map) {
    return ChatMessageModel(
      id: map[AppConstants.colId] as String,
      sessionId: map[AppConstants.colSessionId] as String,
      role: map[AppConstants.colRole] as String,
      content: map[AppConstants.colContent] as String,
      timestamp: map[AppConstants.colTimestamp] as int,
      provider: map[AppConstants.colProvider] as String?,
      attachments: _attachmentsFromMapValue(map[AppConstants.colAttachments]),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      AppConstants.colId: id,
      AppConstants.colSessionId: sessionId,
      AppConstants.colRole: role,
      AppConstants.colContent: content,
      AppConstants.colTimestamp: timestamp,
      AppConstants.colProvider: provider,
      AppConstants.colAttachments: jsonEncode(
        attachments.map((attachment) => attachment.toJson()).toList(),
      ),
    };
  }

  static List<ChatAttachment> _attachmentsFromMapValue(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return const <ChatAttachment>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <ChatAttachment>[];
      return decoded
          .whereType<Map>()
          .map((item) => ChatAttachment.fromJson(
                Map<String, dynamic>.from(item),
              ))
          .toList(growable: false);
    } catch (_) {
      return const <ChatAttachment>[];
    }
  }
}

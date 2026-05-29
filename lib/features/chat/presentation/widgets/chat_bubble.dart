import 'dart:io';

import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/core/runtime/chat_ui_preferences_service.dart';
import 'package:ai_orchestrator/features/chat/domain/entities/chat_message.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class ChatBubble extends StatelessWidget {
  const ChatBubble({
    super.key,
    required this.message,
    this.assistantTextSize = AssistantMessageTextSize.medium,
  });

  final ChatMessage message;
  final AssistantMessageTextSize assistantTextSize;

  bool get _isUser => message.role == 'user';

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
      child: Row(
        mainAxisAlignment:
            _isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!_isUser) _Avatar(provider: message.provider),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: _isUser
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: _isUser
                          ? [
                              const Color(0xFF21416B),
                              const Color(0xFF17273A),
                            ]
                          : [
                              const Color(0xFF171D29),
                              const Color(0xFF12161F),
                            ],
                    ),
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(22),
                      topRight: const Radius.circular(22),
                      bottomLeft: Radius.circular(_isUser ? 22 : 8),
                      bottomRight: Radius.circular(_isUser ? 8 : 22),
                    ),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (message.attachments.isNotEmpty) ...[
                        Column(
                          children: message.attachments
                              .map(
                                (attachment) => Padding(
                                  padding: const EdgeInsets.only(bottom: 10),
                                  child: _AttachmentBubbleCard(
                                    attachment: attachment,
                                  ),
                                ),
                              )
                              .toList(growable: false),
                        ),
                      ],
                      if (message.content.trim().isNotEmpty)
                        Text(
                          message.content,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize:
                                _isUser ? 15 : assistantTextSize.fontSize,
                            height: 1.45,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  DateFormat('HH:mm').format(
                    DateTime.fromMillisecondsSinceEpoch(message.timestamp),
                  ),
                  style: const TextStyle(color: Colors.white30, fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (_isUser)
            const CircleAvatar(
              radius: 14,
              backgroundColor: Color(0xFF8AB4F8),
              child: Icon(Icons.person, color: Colors.black, size: 16),
            ),
        ],
      ),
    );
  }
}

class _AttachmentBubbleCard extends StatelessWidget {
  const _AttachmentBubbleCard({required this.attachment});

  final ChatAttachment attachment;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 180, maxWidth: 280),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          _AttachmentThumb(attachment: attachment),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  attachment.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _uploadLabel(attachment.uploadState),
                  style: TextStyle(
                    color: const Color(0xFF8AB4F8).withValues(alpha: 0.88),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _uploadLabel(ChatAttachmentUploadState state) {
    switch (state) {
      case ChatAttachmentUploadState.preparing:
        return 'Preparing';
      case ChatAttachmentUploadState.ready:
        return 'Attached';
      case ChatAttachmentUploadState.failed:
        return 'Failed';
    }
  }
}

class _AttachmentThumb extends StatelessWidget {
  const _AttachmentThumb({required this.attachment});

  final ChatAttachment attachment;

  @override
  Widget build(BuildContext context) {
    if (attachment.isImage && attachment.thumbnailPath != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Image.file(
          File(attachment.thumbnailPath!),
          width: 52,
          height: 52,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _fallbackIcon(),
        ),
      );
    }
    return _fallbackIcon();
  }

  Widget _fallbackIcon() {
    final icon = switch (attachment.type) {
      ChatAttachmentType.image => Icons.image_outlined,
      ChatAttachmentType.video => Icons.video_library_outlined,
      ChatAttachmentType.file => Icons.description_outlined,
    };
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(icon, color: const Color(0xFF8AB4F8)),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({this.provider});

  final String? provider;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [
            const Color(0xFF1A2235).withValues(alpha: 0.98),
            const Color(0xFF10131A).withValues(alpha: 0.98),
          ],
        ),
      ),
      child: Center(
        child: Text(
          provider?.isNotEmpty == true ? provider![0].toUpperCase() : 'AI',
          style: const TextStyle(
            color: Color(0xFF8AB4F8),
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

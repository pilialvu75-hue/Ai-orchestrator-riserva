import 'dart:io';
import 'dart:math' as math;

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
                        )
                      else if (!_isUser && message.isPending)
                        // Show animated typing dots while the assistant
                        // placeholder has no content yet (pre-first-token
                        // phase).  Without this, the bubble renders as an
                        // invisible empty container for up to 140 seconds
                        // during model warmup.
                        const _TypingIndicator(),
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

/// Animated three-dot typing indicator shown in the assistant bubble while
/// a [ChatMessage.isPending] placeholder has empty content (pre-first-token
/// phase).  Each dot fades in/out with a staggered 160 ms phase offset, giving
/// a natural "thinking" rhythm without requiring external animation packages.
class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 960),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 20,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          return AnimatedBuilder(
            animation: _controller,
            builder: (_, __) {
              // Each dot lags 160 ms behind the previous one.
              final phase = (_controller.value - i * (160 / 960)) % 1.0;
              // Sine wave maps 0→0→1→0 over one cycle.
              final opacity = (math.sin(phase * 2 * math.pi) * 0.5 + 0.5)
                  .clamp(0.25, 1.0);
              return Padding(
                padding: EdgeInsets.only(right: i < 2 ? 5 : 0),
                child: Opacity(
                  opacity: opacity,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                      color: Color(0xFF8AB4F8),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            },
          );
        }),
      ),
    );
  }
}

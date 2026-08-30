import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/core/runtime/chat_ui_preferences_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/features/chat/presentation/widgets/chat_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class HighPerformanceChatList extends StatelessWidget {
  const HighPerformanceChatList({
    super.key,
    required this.controller,
    required this.messages,
    required this.assistantTextSize,
    this.onEditUserMessage,
    this.onSpeakAssistantMessage,
  });

  final ScrollController controller;
  final List<ChatMessage> messages;
  final AssistantMessageTextSize assistantTextSize;

  /// Invoked when the user selects "Modifica" from the context menu
  /// displayed for a user message.
  final ValueChanged<ChatMessage>? onEditUserMessage;

  /// Invoked when the user selects "Ascolta" below an assistant message.
  final ValueChanged<ChatMessage>? onSpeakAssistantMessage;

  Future<void> _showUserContextMenu(
    BuildContext context,
    Offset position,
    ChatMessage message,
  ) async {
    HapticFeedback.lightImpact();

    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;

    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 30, 30),
        Offset.zero & overlay.size,
      ),
      color: const Color(0xFF1E1F20),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(
          color: Colors.white12,
          width: 1,
        ),
      ),
      items: const [
        PopupMenuItem<String>(
          value: 'copy',
          child: Row(
            children: [
              Icon(
                Icons.copy_rounded,
                size: 20,
                color: Colors.white70,
              ),
              SizedBox(width: 10),
              Text(
                'Copia',
                style: TextStyle(color: Colors.white),
              ),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'edit',
          child: Row(
            children: [
              Icon(
                Icons.edit_rounded,
                size: 20,
                color: Colors.white70,
              ),
              SizedBox(width: 10),
              Text(
                'Modifica',
                style: TextStyle(color: Colors.white),
              ),
            ],
          ),
        ),
      ],
    );

    if (!context.mounted || selected == null) {
      return;
    }

    switch (selected) {
      case 'copy':
        _copyToClipboard(
          context,
          message.content,
          'Messaggio copiato negli appunti!',
        );
        break;

      case 'edit':
        onEditUserMessage?.call(message);
        break;
    }
  }

  void _copyToClipboard(
    BuildContext context,
    String text,
    String confirmation,
  ) {
    if (text.trim().isEmpty) {
      return;
    }

    Clipboard.setData(
      ClipboardData(text: text),
    ).then((_) {
      if (!context.mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(
                Icons.assignment_turned_in_rounded,
                color: Color(0xFF4ADE80),
                size: 18,
              ),
              const SizedBox(width: 10),
              Text(
                confirmation,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          backgroundColor: const Color(0xFF1E1F20),
          behavior: SnackBarBehavior.floating,
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(
              color: Colors.white12,
              width: 1,
            ),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    });
  }

  void _onSpeakAssistantMessage(
    BuildContext context,
    ChatMessage message,
  ) {
    final callback = onSpeakAssistantMessage;

    if (callback == null) {
      RuntimeEventLog.instance.emit(
        '[VOICE_ICON_BLOCKED] callback_unavailable '
        'message_id=${message.id}',
      );
      return;
    }

    if (message.content.trim().isEmpty) {
      RuntimeEventLog.instance.emit(
        '[VOICE_ICON_BLOCKED] empty_message '
        'message_id=${message.id}',
      );
      return;
    }

    RuntimeEventLog.instance.emit(
      '[VOICE_ICON_TAP] message_id=${message.id}',
    );

    try {
      callback(message);
    } catch (error) {
      RuntimeEventLog.instance.emit(
        '[VOICE_ICON_CALLBACK_FAIL] '
        'message_id=${message.id} '
        'error=$error',
      );

      if (!context.mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Impossibile avviare la riproduzione vocale.'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Widget _buildAssistantActions(
    BuildContext context,
    ChatMessage message,
  ) {
    return Padding(
      padding: const EdgeInsets.only(
        left: 12,
        top: 2,
        bottom: 4,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _MessageActionButton(
            icon: Icons.volume_up_outlined,
            tooltip: 'Ascolta',
            onPressed: onSpeakAssistantMessage == null
                ? null
                : () => _onSpeakAssistantMessage(
                      context,
                      message,
                    ),
          ),
          _MessageActionButton(
            icon: Icons.copy_outlined,
            tooltip: 'Copia',
            onPressed: () => _copyToClipboard(
              context,
              message.content,
              'Risposta copiata negli appunti!',
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return const Center(
        child: Text(
          'Nessun messaggio in questa sessione',
          style: TextStyle(
            color: Color(0xFF8E9194),
          ),
        ),
      );
    }

    return ListView.builder(
      controller: controller,
      cacheExtent: 1200.0,
      keyboardDismissBehavior:
          ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.symmetric(vertical: 12),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];

        final isUser = message.role == 'user';
        final isAssistant = message.role == 'assistant';

        final bubble = RepaintBoundary(
          child: _AnimatedBubble(
            key: ValueKey(message.id),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onLongPressStart: isUser
                  ? (details) => _showUserContextMenu(
                        context,
                        details.globalPosition,
                        message,
                      )
                  : null,
              child: ChatBubble(
                message: message,
                assistantTextSize: assistantTextSize,
              ),
            ),
          ),
        );

        if (!isAssistant) {
          return bubble;
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            bubble,
            _buildAssistantActions(
              context,
              message,
            ),
          ],
        );
      },
    );
  }
}

class _MessageActionButton extends StatelessWidget {
  const _MessageActionButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      splashRadius: 18,
      padding: const EdgeInsets.all(7),
      constraints: const BoxConstraints(
        minWidth: 34,
        minHeight: 34,
      ),
      icon: Icon(
        icon,
        size: 19,
        color: onPressed == null
            ? const Color(0xFF55585B)
            : const Color(0xFF8E9194),
      ),
    );
  }
}

class _AnimatedBubble extends StatefulWidget {
  const _AnimatedBubble({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  State<_AnimatedBubble> createState() => _AnimatedBubbleState();
}

class _AnimatedBubbleState extends State<_AnimatedBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();

    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );

    _opacity = CurvedAnimation(
      parent: _ctrl,
      curve: Curves.easeOut,
    );

    _slide = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: Curves.easeOut,
      ),
    );

    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(
        position: _slide,
        child: widget.child,
      ),
    );
  }
}

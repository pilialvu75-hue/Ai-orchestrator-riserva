import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/core/runtime/chat_ui_preferences_service.dart';
import 'package:ai_orchestrator/features/chat/presentation/widgets/chat_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class HighPerformanceChatList extends StatelessWidget {
  const HighPerformanceChatList({
    super.key,
    required this.controller,
    required this.messages,
    required this.assistantTextSize,
  });

  final ScrollController controller;
  final List<ChatMessage> messages;
  final AssistantMessageTextSize assistantTextSize;

  Future<void> _showContextMenu(
    BuildContext context,
    Offset position,
    String text,
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
        side: const BorderSide(color: Colors.white12, width: 1),
      ),
      items: const [
        PopupMenuItem<String>(
          value: 'copy',
          child: Row(
            children: [
              Icon(Icons.copy_rounded, size: 20, color: Colors.white70),
              SizedBox(width: 10),
              Text('Copia', style: TextStyle(color: Colors.white)),
            ],
          ),
        ),
      ],
    );

    if (!context.mounted || selected != 'copy') return;
    _copyToClipboard(context, text);
  }

  void _copyToClipboard(BuildContext context, String text) {
    if (text.trim().isEmpty) return;
    Clipboard.setData(ClipboardData(text: text)).then((_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(
                Icons.assignment_turned_in_rounded,
                color: Color(0xFF4ADE80),
                size: 18,
              ),
              SizedBox(width: 10),
              Text(
                'Risposta copiata negli appunti!',
                style: TextStyle(
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
            side: const BorderSide(color: Colors.white12, width: 1),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return const Center(
        child: Text(
          'Nessun messaggio in questa sessione',
          style: TextStyle(color: Color(0xFF8E9194)),
        ),
      );
    }

    return ListView.builder(
      controller: controller,
      cacheExtent: 1200.0,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.symmetric(vertical: 12),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];
        return RepaintBoundary(
          child: _AnimatedBubble(
            key: ValueKey(message.id),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onLongPressStart: (details) => _showContextMenu(
                context,
                details.globalPosition,
                message.content,
              ),
              child: ChatBubble(
                message: message,
                assistantTextSize: assistantTextSize,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AnimatedBubble extends StatefulWidget {
  const _AnimatedBubble({super.key, required this.child});

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
    _opacity = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
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
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}

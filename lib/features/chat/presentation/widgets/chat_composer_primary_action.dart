import 'package:flutter/material.dart';

/// Uses the same 42dp action slot as Send: Live is available when the
/// composer is empty, while Send takes its place once there is draft text
/// or a pending attachment. The microphone remains a separate button.
class ChatComposerPrimaryAction extends StatelessWidget {
  const ChatComposerPrimaryAction({
    super.key,
    required this.hasDraft,
    required this.isLoading,
    required this.liveEnabled,
    required this.onSend,
    required this.onLive,
    required this.sendTooltip,
    required this.emptyTooltip,
  });

  final bool hasDraft;
  final bool isLoading;
  final bool liveEnabled;
  final VoidCallback onSend;
  final VoidCallback? onLive;
  final String sendTooltip;
  final String emptyTooltip;

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const SizedBox(
        width: 42,
        height: 42,
        child: Padding(
          padding: EdgeInsets.all(9),
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Color(0xFF8AB4F8),
          ),
        ),
      );
    }
    if (!hasDraft && liveEnabled && onLive != null) {
      return IconButton(
        tooltip: 'Avvia Live',
        onPressed: onLive,
        style: IconButton.styleFrom(
          backgroundColor: const Color(0xFF8AB4F8),
          foregroundColor: const Color(0xFF0C1929),
          minimumSize: const Size(42, 42),
          maximumSize: const Size(42, 42),
        ),
        icon: const Icon(Icons.graphic_eq_rounded, size: 22),
      );
    }
    return IconButton(
      tooltip: hasDraft ? sendTooltip : emptyTooltip,
      onPressed: hasDraft ? onSend : null,
      style: IconButton.styleFrom(
        backgroundColor: hasDraft
            ? const Color(0xFF8AB4F8)
            : Colors.white.withValues(alpha: 0.08),
        foregroundColor: hasDraft ? Colors.black : Colors.white30,
        minimumSize: const Size(42, 42),
        maximumSize: const Size(42, 42),
      ),
      icon: const Icon(Icons.arrow_upward, size: 20),
    );
  }
}

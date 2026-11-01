import 'package:flutter/material.dart';

/// Live voice uses the send slot while the draft is empty; the microphone
/// remains a separate dictation action.
class ChatLiveButton extends StatelessWidget {
  const ChatLiveButton({super.key, required this.enabled, required this.onPressed});

  final bool enabled;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Avvia conversazione Live',
    onPressed: enabled ? onPressed : null,
    style: IconButton.styleFrom(
      minimumSize: const Size(42, 42),
      maximumSize: const Size(42, 42),
      backgroundColor: enabled
          ? const Color(0xFF8AB4F8)
          : Colors.white.withValues(alpha: 0.08),
      foregroundColor: enabled ? const Color(0xFF101827) : Colors.white38,
    ),
    icon: const Icon(Icons.graphic_eq_rounded, size: 23),
  );
}

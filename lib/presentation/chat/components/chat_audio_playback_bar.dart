import 'package:flutter/material.dart';

/// Controls backed by VoiceOutputService. AudioStreamPlayer currently supports
/// stop, not sample-accurate pause or seek: "Ricomincia" always starts at 0.
/// This UI deliberately does not display fabricated timestamps or progress.
class ChatAudioPlaybackBar extends StatelessWidget {
  const ChatAudioPlaybackBar({
    super.key,
    required this.isPlaying,
    required this.isBusy,
    required this.onStop,
    required this.onRestart,
    required this.onClose,
  });

  final bool isPlaying;
  final bool isBusy;
  final VoidCallback onStop;
  final VoidCallback onRestart;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final status = isBusy
        ? 'Preparazione audio'
        : isPlaying
            ? 'Riproduzione vocale'
            : 'Lettura interrotta';

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFF1B293C),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          children: [
            if (isBusy)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFF8AB4F8),
                ),
              )
            else
              Icon(
                isPlaying ? Icons.graphic_eq_rounded : Icons.volume_off_outlined,
                size: 20,
                color: const Color(0xFF8AB4F8),
              ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
            IconButton(
              tooltip: 'Ricomincia dall’inizio',
              onPressed: isBusy ? null : onRestart,
              icon: const Icon(Icons.replay_rounded),
              iconSize: 20,
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              color: Colors.white,
            ),
            IconButton(
              tooltip: 'Interrompi lettura',
              onPressed: isBusy || !isPlaying ? null : onStop,
              icon: const Icon(Icons.stop_circle_outlined),
              iconSize: 21,
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              color: Colors.white,
            ),
            IconButton(
              tooltip: 'Chiudi lettore',
              onPressed: onClose,
              icon: const Icon(Icons.close_rounded),
              iconSize: 21,
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              color: Colors.white70,
            ),
          ],
        ),
      ),
    );
  }
}
